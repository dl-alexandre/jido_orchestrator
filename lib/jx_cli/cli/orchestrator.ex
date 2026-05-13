defmodule JX.CLI.Orchestrator do
  @moduledoc false

  alias JX.OrchestratorDaemon
  alias JX.OrchestratorHeartbeats
  alias JX.Tmux
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @usage "jx orchestrator start|status|stop|logs|health|heartbeats|inbox|review <ref>|decide <ref> [--prompt <text> --ready|--draft | --hold <reason> | --clear | --ignore | --protect | --managed] [--dry-run] [--session #{OrchestratorDaemon.default_session_name()}] [--server #{Tmux.managed_server()}] [--log <path>] [--json]"
  @heartbeats_usage "jx orchestrator heartbeats [--consumer <name>] [--status running|idle|error|stopped] [-n 20] [--json]"
  @health_usage "jx orchestrator health [--consumer <name>] [--status running|idle|error|stopped] [--stale-after-seconds 120] [-n 20] [--json]"

  def usage_lines, do: [@usage]
  def usage, do: @usage

  def run(["start" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          session: :string,
          server: :string,
          log: :string,
          replace: :boolean,
          dry_run: :boolean,
          consumer: :string,
          host: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          work_state: :string,
          control: :string,
          prompt_status: :string,
          observe: :boolean,
          lines: :integer,
          scan_limit: :integer,
          queue_limit: :integer,
          event_limit: :integer,
          decision_limit: :integer,
          min_observe_age_seconds: :integer,
          interval_ms: :integer,
          execute: :boolean,
          yes: :boolean,
          ack: :boolean,
          auto_plan: :boolean,
          no_enter: :boolean,
          json: :boolean
        ]
      )

    lines = parsed[:lines] || 160
    scan_limit = parsed[:scan_limit] || 100
    queue_limit = parsed[:queue_limit] || 10
    event_limit = parsed[:event_limit] || 50
    decision_limit = parsed[:decision_limit] || 20
    min_observe_age_seconds = parsed[:min_observe_age_seconds] || 15
    interval_ms = parsed[:interval_ms] || 15_000
    server = parsed[:server] || Tmux.managed_server()

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @usage),
         :ok <- validate_tmux_server(server),
         :ok <- validate_optional_session_type(parsed[:type]),
         :ok <- validate_optional_work_state(parsed[:work_state]),
         :ok <- validate_optional_work_board_control(parsed[:control]),
         :ok <- validate_optional_prompt_status(parsed[:prompt_status]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("queue-limit", queue_limit),
         :ok <- validate_positive("event-limit", event_limit),
         :ok <- validate_positive("decision-limit", decision_limit),
         :ok <- validate_non_negative("min-observe-age-seconds", min_observe_age_seconds),
         :ok <- validate_positive("interval-ms", interval_ms),
         :ok <- start_app(opts),
         {:ok, status} <-
           apply(daemon(opts), :start, [
             orchestrator_daemon_opts(parsed,
               server: server,
               lines: lines,
               scan_limit: scan_limit,
               queue_limit: queue_limit,
               event_limit: event_limit,
               decision_limit: decision_limit,
               min_observe_age_seconds: min_observe_age_seconds,
               interval_ms: interval_ms,
               db_path: database_path(opts)
             )
           ]) do
      print_orchestrator_daemon_status(status, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["status" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [session: :string, server: :string, log: :string, json: :boolean]
      )

    server = parsed[:server] || Tmux.managed_server()

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @usage),
         :ok <- validate_tmux_server(server),
         {:ok, status} <-
           apply(daemon(opts), :status, [orchestrator_daemon_opts(parsed, server: server)]) do
      print_orchestrator_daemon_status(status, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["stop" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [session: :string, server: :string, log: :string, json: :boolean]
      )

    server = parsed[:server] || Tmux.managed_server()

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @usage),
         :ok <- validate_tmux_server(server),
         {:ok, status} <-
           apply(daemon(opts), :stop, [orchestrator_daemon_opts(parsed, server: server)]) do
      print_orchestrator_daemon_status(status, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["logs" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [session: :string, server: :string, log: :string, n: :integer, json: :boolean],
        aliases: [n: :n]
      )

    lines = parsed[:n] || 80
    server = parsed[:server] || Tmux.managed_server()

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @usage),
         :ok <- validate_tmux_server(server),
         :ok <- validate_positive("n", lines),
         {:ok, log} <-
           apply(daemon(opts), :logs, [
             orchestrator_daemon_opts(parsed, server: server, lines: lines)
           ]) do
      if parsed[:json] do
        print_json(log)
      else
        IO.write(log.output)
        if log.output != "" and not String.ends_with?(log.output, "\n"), do: IO.puts("")
      end

      :ok
    end
  end

  def run(["heartbeats" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [consumer: :string, status: :string, n: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @heartbeats_usage),
         :ok <- validate_optional_heartbeat_status(parsed[:status]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:list_orchestrator_heartbeats, [
        [consumer: parsed[:consumer], status: parsed[:status], limit: limit]
      ])
      |> print_orchestrator_heartbeats(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["health" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          consumer: :string,
          status: :string,
          stale_after_seconds: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 20
    stale_after_seconds = parsed[:stale_after_seconds] || 120

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @health_usage),
         :ok <- validate_optional_heartbeat_status(parsed[:status]),
         :ok <- validate_positive("stale-after-seconds", stale_after_seconds),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:orchestrator_health, [
        [
          consumer: parsed[:consumer],
          status: parsed[:status],
          stale_after_seconds: stale_after_seconds,
          limit: limit
        ]
      ])
      |> print_orchestrator_health(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["inbox" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          project: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          work_state: :string,
          control: :string,
          observe: :boolean,
          lines: :integer,
          scan_limit: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    lines = parsed[:lines] || 160
    limit = parsed[:n] || 20
    scan_limit = parsed[:scan_limit] || 100

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @usage),
         :ok <- validate_optional_session_type(parsed[:type]),
         :ok <- validate_optional_work_state(parsed[:work_state]),
         :ok <- validate_optional_work_board_control(parsed[:control]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts),
         {:ok, inbox} <-
           apply(workspace(opts), :orchestrator_inbox, [
             [
               host_name: parsed[:host],
               all_tmux: !parsed[:managed],
               all_processes: parsed[:all_processes] || false,
               type: parsed[:type],
               ssh_target: parsed[:ssh_target],
               work_state: parsed[:work_state],
               control_mode: parsed[:control],
               observe: Keyword.get(parsed, :observe, true),
               lines: lines,
               scan_limit: scan_limit,
               limit: limit
             ]
           ]) do
      print_orchestrator_inbox(inbox, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["review", ref | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          observe: :boolean,
          lines: :integer,
          json: :boolean
        ]
      )

    lines = parsed[:lines] || 220

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @usage),
         :ok <- validate_positive("lines", lines),
         :ok <- start_app(opts),
         {:ok, review} <-
           apply(workspace(opts), :orchestrator_review, [
             ref,
             [observe: Keyword.get(parsed, :observe, true), lines: lines]
           ]) do
      print_orchestrator_review(review, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["decide", ref | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          prompt: :string,
          ready: :boolean,
          draft: :boolean,
          hold: :string,
          clear: :boolean,
          ignore: :boolean,
          protect: :boolean,
          managed: :boolean,
          note: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @usage),
         {:ok, attrs} <- orchestrator_decide_attrs(parsed),
         :ok <- start_app(opts),
         {:ok, result} <- apply(workspace(opts), :orchestrator_decide, [ref, attrs]) do
      print_orchestrator_decision(result, json: parsed[:json] || false)
      :ok
    end
  end

  def run(_args, _opts), do: {:error, "usage: #{usage()}"}

  defp workspace(opts), do: Keyword.get(opts, :workspace, Workspace)
  defp daemon(opts), do: Keyword.get(opts, :daemon, OrchestratorDaemon)

  defp start_app(opts) do
    case Keyword.fetch(opts, :start_app) do
      {:ok, start_app} -> start_app.()
      :error -> {:error, :missing_start_app_callback}
    end
  end

  defp database_path(opts) do
    case Keyword.get(opts, :database_path) do
      database_path when is_function(database_path, 0) -> database_path.()
      database_path -> database_path
    end
  end

  defp orchestrator_decide_attrs(opts) do
    actions =
      [
        prompt: opts[:prompt],
        hold: opts[:hold],
        clear: opts[:clear],
        ignore: opts[:ignore],
        protect: opts[:protect],
        managed: opts[:managed]
      ]
      |> Enum.filter(fn
        {_action, value} when is_binary(value) -> String.trim(value) != ""
        {_action, value} -> value == true
      end)

    cond do
      length(actions) != 1 ->
        {:error,
         "choose exactly one decision action: --prompt, --hold, --clear, --ignore, --protect, or --managed"}

      opts[:ready] && opts[:draft] ->
        {:error, "use either --ready or --draft, not both"}

      true ->
        {action, value} = hd(actions)
        prompt_status = if opts[:draft], do: "draft", else: "ready"

        attrs =
          case action do
            :prompt ->
              %{action: "prompt", prompt: value, prompt_status: prompt_status}

            :hold ->
              %{action: "hold", reason: value}

            action when action in [:clear, :ignore, :protect, :managed] ->
              %{action: Atom.to_string(action)}
          end

        attrs =
          if opts[:note] do
            Map.put(attrs, :notes, opts[:note])
          else
            attrs
          end

        {:ok, attrs}
    end
  end

  defp orchestrator_daemon_opts(opts, overrides) do
    [
      session_name: opts[:session],
      tmux_server: overrides[:server],
      log_path: opts[:log],
      db_path: overrides[:db_path],
      dry_run: opts[:dry_run] || false,
      consumer: opts[:consumer],
      host_name: opts[:host],
      all_tmux: !opts[:managed],
      all_processes: opts[:all_processes] || false,
      type: opts[:type],
      ssh_target: opts[:ssh_target],
      work_state: opts[:work_state],
      control_mode: opts[:control],
      prompt_status: opts[:prompt_status],
      observe: Keyword.get(opts, :observe, true),
      lines: overrides[:lines],
      scan_limit: overrides[:scan_limit],
      queue_limit: overrides[:queue_limit],
      event_limit: overrides[:event_limit],
      decision_limit: overrides[:decision_limit],
      min_observe_age_seconds: overrides[:min_observe_age_seconds],
      interval_ms: overrides[:interval_ms],
      execute: Keyword.get(opts, :execute, true),
      yes: Keyword.get(opts, :yes, true),
      ack: Keyword.get(opts, :ack, true),
      auto_plan: Keyword.get(opts, :auto_plan, true),
      enter: !opts[:no_enter],
      replace: opts[:replace] || false
    ]
  end

  defp print_orchestrator_daemon_status(status, opts) do
    if opts[:json] do
      print_json(status)
    else
      state = if status.running, do: "running", else: "stopped"

      IO.puts("orchestrator #{state}")
      IO.puts("session: #{status.session_name}")
      IO.puts("server: #{status.tmux_server}")
      IO.puts("log: #{status.log_path}")

      if status[:command], do: IO.puts("command: #{status.command}")
      if status[:pane_pid], do: IO.puts("pid: #{status.pane_pid}")
      if status[:current_path], do: IO.puts("path: #{status.current_path}")
    end
  end

  defp print_orchestrator_inbox(inbox, opts) do
    if opts[:json] do
      print_json(json_orchestrator_inbox(inbox))
    else
      IO.puts("orchestrator inbox")
      IO.puts("generated: #{format_time(inbox.generated_at)}")

      print_inbox_section("needs judgment", inbox.sections.needs_judgment)
      print_inbox_delegation_reviews(Map.get(inbox.sections, :delegation_reviews, []))
      print_recovery_recommendations(Map.get(inbox.sections, :recovery, %{}))
      print_inbox_suggestions(inbox.sections.suggestions)
      print_inbox_section("ready / chambered", inbox.sections.ready)
      print_inbox_section("awaiting observation", inbox.sections.awaiting_observation)
      print_inbox_section("recently completed", inbox.sections.recently_completed)

      IO.puts("")
      print_summary_counts("observation refresh", inbox.observation_refresh)

      unless inbox.errors == [] do
        IO.puts("")
        print_summary_errors(inbox.errors)
      end
    end
  end

  defp print_inbox_section(_title, []), do: :ok

  defp print_inbox_section(title, items) do
    IO.puts("")
    IO.puts(title)

    rows =
      Enum.map(items, fn item ->
        [
          item.ref,
          item.project,
          item.state,
          item.prompt_status,
          item.work_state,
          truncate(item.next_step, 32),
          truncate(item.actual, 72)
        ]
      end)

    print_table(["REF", "PROJECT", "STATE", "PROMPT", "WORK", "NEXT", "ACTUAL"], rows)
  end

  defp print_inbox_delegation_reviews([]), do: :ok

  defp print_inbox_delegation_reviews(reviews) do
    IO.puts("")
    IO.puts("delegation reviews")

    rows =
      Enum.map(reviews, fn review ->
        [
          Map.get(review, :delegation_id, ""),
          Map.get(review, :decision, ""),
          Map.get(review, :ref, ""),
          truncate(Map.get(review, :project, ""), 24),
          truncate(Map.get(review, :title, ""), 36),
          truncate(Map.get(review, :summary, ""), 72)
        ]
      end)

    print_table(["ID", "DECISION", "REF", "PROJECT", "TITLE", "SUMMARY"], rows)
  end

  defp print_recovery_recommendations(%{recommendations: []}), do: :ok

  defp print_recovery_recommendations(%{recommendations: recommendations}) do
    IO.puts("")
    IO.puts("recovery recommendations")

    rows =
      Enum.map(recommendations, fn recommendation ->
        [
          recommendation.action,
          recommendation.safety,
          recommendation.ref,
          truncate(recommendation.target, 40),
          truncate(recommendation.reason, 72),
          truncate(Enum.join(recommendation.evidence, "; "), 72)
        ]
      end)

    print_table(["ACTION", "SAFETY", "REF", "TARGET", "REASON", "EVIDENCE"], rows)
  end

  defp print_recovery_recommendations(_recovery), do: :ok

  defp print_inbox_suggestions([]), do: :ok

  defp print_inbox_suggestions(suggestions) do
    IO.puts("")
    IO.puts("planner suggestions")

    rows =
      Enum.map(suggestions, fn suggestion ->
        [
          suggestion.ref,
          suggestion.project,
          suggestion.safety,
          suggestion.prompt_status,
          truncate(suggestion.reason, 40),
          truncate(suggestion.prompt, 96)
        ]
      end)

    print_table(["REF", "PROJECT", "SAFETY", "PROMPT", "REASON", "PLAN"], rows)
  end

  defp print_orchestrator_review(review, opts) do
    if opts[:json] do
      print_json(json_orchestrator_review(review))
    else
      profile = review.profile
      recommendation = review.recommendation

      IO.puts("orchestrator review #{review.ref}")
      IO.puts("generated: #{format_time(review.generated_at)}")
      IO.puts("project: #{get_in(profile, [:session, :project]) || ""}")
      IO.puts("state: #{get_in(profile, [:comparison, :state]) || ""}")
      IO.puts("prompt: #{get_in(profile, [:next_prompt, :status]) || ""}")
      IO.puts("work: #{get_in(profile, [:actual, :work_state]) || ""}")
      IO.puts("actual: #{get_in(profile, [:comparison, :actual_summary]) || ""}")

      if review.latest_observation do
        IO.puts("")
        IO.puts("latest observation")
        print_summary_counts("observation", review.latest_observation)
      end

      IO.puts("")
      IO.puts("recommendation")
      IO.puts("type: #{recommendation.type}")
      IO.puts("safety: #{recommendation.safety}")
      IO.puts("reason: #{recommendation.reason}")

      if String.trim(recommendation.prompt || "") != "" do
        IO.puts("")
        IO.puts("prompt")
        IO.puts(recommendation.prompt)
      end

      print_review_evidence(recommendation.evidence || [])
      print_review_commands(review.commands)

      unless review.errors == [] do
        IO.puts("")
        print_summary_errors(review.errors)
      end
    end
  end

  defp print_review_evidence([]), do: :ok

  defp print_review_evidence(evidence) do
    IO.puts("")
    IO.puts("evidence")
    Enum.each(evidence, &IO.puts("- #{&1}"))
  end

  defp print_review_commands([]), do: :ok

  defp print_review_commands(commands) do
    IO.puts("")
    IO.puts("commands")

    rows =
      Enum.map(commands, fn command ->
        [command.action, command.command]
      end)

    print_table(["ACTION", "COMMAND"], rows)
  end

  defp print_orchestrator_decision(result, opts) do
    if opts[:json] do
      print_json(json_orchestrator_decision(result))
    else
      IO.puts("#{result.result_summary}: #{result.ref}")
    end
  end

  defp print_orchestrator_heartbeats([], opts) do
    if opts[:json] do
      print_json(%{heartbeats: []})
    else
      IO.puts("no orchestrator heartbeats")
    end
  end

  defp print_orchestrator_heartbeats(heartbeats, opts) do
    if opts[:json] do
      print_json(%{heartbeats: Enum.map(heartbeats, &json_orchestrator_heartbeat/1)})
    else
      rows =
        Enum.map(heartbeats, fn heartbeat ->
          guidance = heartbeat_guidance(heartbeat)

          [
            heartbeat.daemon_key,
            heartbeat.status,
            heartbeat.consumer,
            heartbeat.mode,
            format_time(heartbeat.last_scan_at),
            format_time(heartbeat.last_decision_at),
            format_time(heartbeat.next_wake_at),
            truncate(Map.get(guidance, "top_priority", ""), 56),
            truncate(Enum.join(Map.get(guidance, "operator_needed_for", []), ","), 40),
            truncate(heartbeat.last_error, 40)
          ]
        end)

      print_table(
        [
          "KEY",
          "STATUS",
          "CONSUMER",
          "MODE",
          "SCAN",
          "DECISION",
          "NEXT",
          "TOP",
          "NEEDS",
          "ERROR"
        ],
        rows
      )
    end
  end

  defp print_orchestrator_health(health, opts) do
    if opts[:json] do
      print_json(json_orchestrator_health(health))
    else
      IO.puts("orchestrator health: #{health.status}")
      IO.puts("alerts: #{health.alerts_total}")
      IO.puts("heartbeats: #{health.heartbeats_total}")

      if health.alerts != [] do
        IO.puts("")
        print_orchestrator_health_alerts(health.alerts)
      end

      if health.heartbeats != [] do
        IO.puts("")
        print_orchestrator_heartbeats(health.heartbeats, json: false)
      end
    end
  end

  defp print_orchestrator_health_alerts(alerts) do
    rows =
      Enum.map(alerts, fn alert ->
        [
          Map.get(alert, :daemon_key, ""),
          Map.get(alert, :severity, ""),
          Map.get(alert, :reason, ""),
          Map.get(alert, :status, ""),
          format_time(Map.get(alert, :last_scan_at)),
          format_time(Map.get(alert, :next_wake_at)),
          truncate(Map.get(alert, :summary, ""), 80)
        ]
      end)

    print_table(["KEY", "SEVERITY", "REASON", "STATUS", "SCAN", "NEXT", "SUMMARY"], rows)
  end

  defp print_summary_counts(name, counts) do
    rows =
      counts
      |> Enum.flat_map(fn
        {key, %_struct{} = value} ->
          [[to_string(key), "", to_string(value)]]

        {key, value} when is_map(value) ->
          value
          |> Enum.map(fn {nested_key, nested_value} ->
            [to_string(key), to_string(nested_key), summary_value(nested_value)]
          end)

        {key, value} when is_integer(value) ->
          [[to_string(key), "", Integer.to_string(value)]]

        {key, value} when is_boolean(value) ->
          [[to_string(key), "", format_bool(value)]]

        {key, value} when is_binary(value) ->
          [[to_string(key), "", value]]

        _other ->
          []
      end)

    IO.puts(name)
    print_table(["METRIC", "KEY", "VALUE"], rows)
  end

  defp print_summary_errors(errors) do
    rows =
      Enum.map(errors, fn error ->
        [
          Map.get(error, :host, ""),
          Map.get(error, :transport, ""),
          Map.get(error, :subsystem, ""),
          format_error(Map.get(error, :error, ""))
        ]
      end)

    print_table(["HOST", "TRANSPORT", "SUBSYSTEM", "ERROR"], rows)
  end

  defp json_orchestrator_inbox(inbox) do
    %{
      generated_at: format_time(inbox.generated_at),
      observed: inbox.observed,
      observation_refresh: inbox.observation_refresh,
      total: inbox.total,
      sections: inbox.sections,
      errors: Enum.map(inbox.errors, &json_error/1)
    }
  end

  defp json_orchestrator_review(review) do
    %{
      generated_at: format_time(review.generated_at),
      ref: review.ref,
      observed: review.observed,
      observation_refresh: review.observation_refresh,
      profile: review.profile,
      latest_observation: json_latest_observation(review.latest_observation),
      recommendation: review.recommendation,
      commands: review.commands,
      errors: Enum.map(review.errors, &json_error/1)
    }
  end

  defp json_latest_observation(nil), do: nil

  defp json_latest_observation(observation) do
    Map.update!(observation, :inserted_at, &format_time/1)
  end

  defp json_orchestrator_decision(result) do
    %{
      ref: result.ref,
      action: result.action,
      result_summary: result.result_summary
    }
  end

  defp json_orchestrator_heartbeat(heartbeat) do
    snapshot = operation_execution_snapshot(heartbeat.scan_snapshot)

    %{
      daemon_key: heartbeat.daemon_key,
      consumer: heartbeat.consumer,
      session_name: heartbeat.session_name,
      status: heartbeat.status,
      mode: heartbeat.mode,
      last_scan_at: format_time(heartbeat.last_scan_at),
      last_decision_at: format_time(heartbeat.last_decision_at),
      last_error: heartbeat.last_error,
      next_wake_at: format_time(heartbeat.next_wake_at),
      guidance: Map.get(snapshot, "guidance", %{}),
      scan_snapshot: snapshot,
      updated_at: format_time(heartbeat.updated_at)
    }
  end

  defp json_orchestrator_health(health) do
    %{
      generated_at: format_time(health.generated_at),
      status: health.status,
      stale_after_seconds: health.stale_after_seconds,
      heartbeats_total: health.heartbeats_total,
      alerts_total: health.alerts_total,
      alerts: Enum.map(health.alerts, &json_orchestrator_health_alert/1),
      heartbeats: Enum.map(health.heartbeats, &json_orchestrator_heartbeat/1)
    }
  end

  defp json_orchestrator_health_alert(alert) do
    %{
      kind: Map.get(alert, :kind, ""),
      reason: Map.get(alert, :reason, ""),
      severity: Map.get(alert, :severity, ""),
      daemon_key: Map.get(alert, :daemon_key, ""),
      consumer: Map.get(alert, :consumer, ""),
      session_name: Map.get(alert, :session_name, ""),
      status: Map.get(alert, :status, ""),
      mode: Map.get(alert, :mode, ""),
      last_scan_at: format_time(Map.get(alert, :last_scan_at)),
      last_decision_at: format_time(Map.get(alert, :last_decision_at)),
      last_error: Map.get(alert, :last_error, ""),
      next_wake_at: format_time(Map.get(alert, :next_wake_at)),
      overdue_seconds: Map.get(alert, :overdue_seconds),
      summary: Map.get(alert, :summary, "")
    }
  end

  defp heartbeat_guidance(heartbeat) do
    case operation_execution_snapshot(heartbeat.scan_snapshot) do
      %{"guidance" => guidance} -> guidance
      _other -> %{}
    end
  end

  defp json_error(error) do
    %{
      host: Map.get(error, :host, ""),
      transport: Map.get(error, :transport, ""),
      subsystem: Map.get(error, :subsystem, ""),
      error: format_error(Map.get(error, :error, ""))
    }
  end

  defp operation_execution_snapshot(snapshot) do
    snapshot
    |> observation_snapshot()
    |> redact_operation_snapshot()
  end

  defp redact_operation_snapshot(%{"capture" => %{"output" => output} = capture} = snapshot)
       when is_binary(output) do
    capture =
      capture
      |> Map.delete("output")
      |> Map.put("output_redacted", true)
      |> Map.put("output_bytes", byte_size(output))

    Map.put(snapshot, "capture", capture)
  end

  defp redact_operation_snapshot(snapshot), do: snapshot

  defp observation_snapshot(snapshot) do
    case Jason.decode(snapshot) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> snapshot
    end
  end

  defp validate_tmux_server(server) do
    if Tmux.valid_server?(server) do
      :ok
    else
      {:error,
       "invalid tmux server #{inspect(server)}; use default, #{Tmux.managed_server()}, socket:<name>, or a tmux -L name"}
    end
  end

  defp validate_optional_session_type(nil), do: :ok

  defp validate_optional_session_type(type) do
    if type in ~w(agent process ssh task tmux) do
      :ok
    else
      {:error,
       "unsupported session type #{inspect(type)}; expected one of: agent, process, ssh, task, tmux"}
    end
  end

  defp validate_optional_work_state(nil), do: :ok

  defp validate_optional_work_state(work_state) do
    if work_state in JX.SessionStatus.work_states() do
      :ok
    else
      {:error,
       "unsupported work state #{inspect(work_state)}; expected one of: #{Enum.join(JX.SessionStatus.work_states(), ", ")}"}
    end
  end

  defp validate_optional_work_board_control(nil), do: :ok
  defp validate_optional_work_board_control("uncontrolled"), do: :ok
  defp validate_optional_work_board_control(mode), do: validate_session_control_mode(mode)

  defp validate_session_control_mode(mode) do
    if mode in JX.SessionControls.modes() do
      :ok
    else
      {:error,
       "unsupported session control mode #{inspect(mode)}; expected one of: #{Enum.join(JX.SessionControls.modes(), ", ")}"}
    end
  end

  defp validate_optional_prompt_status(nil), do: :ok

  defp validate_optional_prompt_status(status) do
    statuses = JX.SessionProfiles.prompt_statuses()

    if status in statuses do
      :ok
    else
      {:error,
       "unsupported prompt status #{inspect(status)}; expected one of: #{Enum.join(statuses, ", ")}"}
    end
  end

  defp validate_optional_heartbeat_status(nil), do: :ok

  defp validate_optional_heartbeat_status(status) do
    statuses = OrchestratorHeartbeats.statuses()

    if status in statuses do
      :ok
    else
      {:error,
       "unsupported heartbeat status #{inspect(status)}; expected one of: #{Enum.join(statuses, ", ")}"}
    end
  end

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp validate_non_negative(_name, value) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative(name, _value), do: {:error, "#{name} must be a non-negative integer"}

  defp summary_value(value) when is_integer(value), do: Integer.to_string(value)
  defp summary_value(value) when is_boolean(value), do: format_bool(value)
  defp summary_value(value) when is_binary(value), do: value
  defp summary_value(%_struct{} = value), do: to_string(value)
  defp summary_value(nil), do: ""
  defp summary_value(value), do: inspect(value)

  defp format_bool(true), do: "yes"
  defp format_bool(false), do: "no"

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp format_time(value) when is_binary(value), do: if(value == "", do: "-", else: value)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp truncate(value, max_length) do
    value = value || ""

    if String.length(value) > max_length do
      String.slice(value, 0, max_length - 3) <> "..."
    else
      value
    end
  end
end
