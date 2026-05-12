defmodule JX.CLI.Orchestrate do
  @moduledoc false

  alias JX.MonitorEvents
  alias JX.OrchestratorHeartbeats
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @usage "jx orchestrate step|run|start [--consumer orchestrator] [--execute] [--yes] [--ack|--no-ack] [--auto-plan] [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--prompt-status none|draft|ready|sent|blocked] [--no-observe] [--lines 40] [--scan-limit 100] [--queue-limit 5] [--event-limit 50] [--decision-limit 20] [--min-observe-age-seconds 30] [--interval-ms 30000] [--iterations 0] [--no-enter] [--json]"

  def usage_lines, do: [@usage]
  def usage, do: @usage

  def run([command | args], opts) when command in ["step", "run", "start"] do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
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
          iterations: :integer,
          execute: :boolean,
          yes: :boolean,
          ack: :boolean,
          auto_plan: :boolean,
          no_enter: :boolean,
          json: :boolean
        ]
      )

    lines = parsed[:lines] || 40
    scan_limit = parsed[:scan_limit] || 100
    queue_limit = parsed[:queue_limit] || 5
    event_limit = parsed[:event_limit] || 50
    decision_limit = parsed[:decision_limit] || 20
    min_observe_age_seconds = parsed[:min_observe_age_seconds] || 30
    interval_ms = parsed[:interval_ms] || 30_000
    iterations = parsed[:iterations] || if(command == "step", do: 1, else: 0)

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @usage),
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
         :ok <- validate_non_negative("iterations", iterations),
         :ok <- start_app(opts) do
      orchestrate_opts =
        [
          consumer: parsed[:consumer],
          host_name: parsed[:host],
          all_tmux: !parsed[:managed],
          all_processes: parsed[:all_processes] || false,
          type: parsed[:type],
          ssh_target: parsed[:ssh_target],
          work_state: parsed[:work_state],
          control_mode: parsed[:control],
          prompt_status: parsed[:prompt_status],
          observe: Keyword.get(parsed, :observe, true),
          lines: lines,
          limit: scan_limit,
          queue_limit: queue_limit,
          event_limit: event_limit,
          decision_limit: decision_limit,
          min_observe_age_seconds: min_observe_age_seconds,
          interval_ms: interval_ms,
          execute: parsed[:execute] || false,
          yes: parsed[:yes] || false,
          auto_plan: parsed[:auto_plan] || false,
          enter: !parsed[:no_enter]
        ]
        |> maybe_put(:ack, parsed[:ack])

      run_orchestrate(command, orchestrate_opts, iterations, interval_ms,
        workspace: workspace(opts),
        json: parsed[:json] || false
      )
    end
  end

  def run(_args, _opts), do: {:error, "usage: #{usage()}"}

  defp workspace(opts), do: Keyword.get(opts, :workspace, Workspace)

  defp start_app(opts) do
    case Keyword.fetch(opts, :start_app) do
      {:ok, start_app} -> start_app.()
      :error -> {:error, :missing_start_app_callback}
    end
  end

  defp run_orchestrate("step", opts, _iterations, _interval_ms, run_opts) do
    with {:ok, report} <- apply(run_opts[:workspace], :orchestrate, [opts]) do
      print_orchestrate_report(report, run_opts)
      :ok
    end
  end

  defp run_orchestrate(command, opts, iterations, interval_ms, run_opts)
       when command in ["run", "start"] do
    orchestrate_loop(opts, iterations, interval_ms, run_opts, 1)
  end

  defp orchestrate_loop(_opts, iterations, _interval_ms, _run_opts, iteration)
       when iterations > 0 and iteration > iterations,
       do: :ok

  defp orchestrate_loop(opts, 0, interval_ms, run_opts, iteration) do
    case orchestrate_iteration(opts, run_opts, iteration) do
      :ok ->
        Process.sleep(interval_ms)
        orchestrate_loop(opts, 0, interval_ms, run_opts, iteration + 1)

      {:error, reason} ->
        print_orchestrate_loop_error(reason, run_opts)
        record_orchestrate_loop_error(opts, interval_ms, reason)
        Process.sleep(interval_ms)
        orchestrate_loop(opts, 0, interval_ms, run_opts, iteration + 1)
    end
  end

  defp orchestrate_loop(opts, iterations, interval_ms, run_opts, iteration) do
    with :ok <- orchestrate_iteration(opts, run_opts, iteration) do
      if iterations == 0 or iteration < iterations do
        Process.sleep(interval_ms)
        orchestrate_loop(opts, iterations, interval_ms, run_opts, iteration + 1)
      else
        :ok
      end
    end
  end

  defp orchestrate_iteration(opts, run_opts, iteration) do
    with {:ok, report} <- orchestrate_fun(run_opts[:workspace]).(opts) do
      IO.puts("orchestrate iteration #{iteration}")
      print_orchestrate_report(report, run_opts)
      :ok
    end
  rescue
    error -> {:error, {:exception, error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:caught, kind, reason, __STACKTRACE__}}
  end

  defp orchestrate_fun(workspace) do
    Process.get(:jx_cli_orchestrate_fun, fn opts -> apply(workspace, :orchestrate, [opts]) end)
  end

  defp print_orchestrate_loop_error(reason, opts) do
    error = orchestrate_loop_error_message(reason)

    if opts[:json] do
      print_json(%{generated_at: DateTime.utc_now() |> DateTime.to_iso8601(), error: error})
    else
      IO.puts(:stderr, "orchestrate iteration failed: #{error}")
    end
  end

  defp record_orchestrate_loop_error(opts, interval_ms, reason) do
    now = DateTime.utc_now()
    error = orchestrate_loop_error_message(reason)

    %{
      daemon_key: Keyword.get(opts, :daemon_key) || orchestrate_consumer(opts),
      consumer: orchestrate_consumer(opts),
      session_name: Keyword.get(opts, :session_name) || "",
      status: "error",
      mode: orchestrate_loop_mode(opts),
      last_scan_at: now,
      last_decision_at: nil,
      last_error: truncate(error, 500),
      next_wake_at: DateTime.add(now, div(interval_ms, 1_000), :second),
      scan_snapshot: Jason.encode!(%{error: error})
    }
    |> OrchestratorHeartbeats.upsert()

    :ok
  rescue
    _error -> :ok
  end

  defp orchestrate_consumer(opts) do
    Keyword.get(opts, :consumer) || MonitorEvents.default_consumer()
  end

  defp orchestrate_loop_mode(opts) do
    execute? = Keyword.get(opts, :execute, false)
    ack? = Keyword.get(opts, :ack, execute?)

    case {execute?, ack?} do
      {true, true} -> "execute+ack"
      {true, false} -> "execute"
      {false, true} -> "ack"
      {false, false} -> "dry-run"
    end
  end

  defp orchestrate_loop_error_message({:exception, error, stacktrace}) do
    Exception.format(:error, error, stacktrace) |> String.trim()
  end

  defp orchestrate_loop_error_message({:caught, kind, reason, stacktrace}) do
    Exception.format(kind, reason, stacktrace) |> String.trim()
  end

  defp orchestrate_loop_error_message(reason), do: format_error(reason)

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

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp validate_non_negative(_name, value) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative(name, _value), do: {:error, "#{name} must be a non-negative integer"}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_orchestrate_report(report, opts) do
    if opts[:json] do
      print_json(json_orchestrate_report(report))
    else
      IO.puts("generated #{format_time(report.generated_at)}")
      IO.puts("consumer #{report.consumer}")
      IO.puts("mode #{report.mode}")
      IO.puts("")

      print_summary_counts("scan", %{
        sessions: report.scan.sessions_total,
        events_saved: report.scan.events_saved,
        queues: report.scan.queues_total,
        watches: Map.get(report.scan, :watches_total, 0),
        watch_actions: Map.get(report.scan, :watch_actions_total, 0),
        ci_watches: Map.get(report.scan, :ci_watches_total, 0),
        delegations: Map.get(report.scan, :delegations_total, 0),
        delegation_reviews: Map.get(report.scan, :delegation_reviews_total, 0),
        delegation_long_running:
          get_in(report.scan, [:delegation_timing, :active, :long_running]) || 0,
        delegation_conflicts: get_in(report.scan, [:delegation_preflight, :conflicts_total]) || 0,
        notifications: Map.get(report.scan, :notifications_saved, 0),
        profiles: report.scan.profiles_total
      })

      IO.puts("")

      print_summary_counts("inbox", %{
        unread: report.inbox.unread_total,
        matching_unread: report.inbox.matching_unread_total,
        returned: report.inbox.returned,
        latest_event: report.inbox.latest_event_id
      })

      IO.puts("")
      print_orchestrator_decisions(report.decisions)
      IO.puts("")
      print_operation_execution(report.execution)

      if report.cursor do
        IO.puts("")
        print_monitor_cursor(report.cursor)
      end

      print_summary_errors_after(report.errors)
    end
  end

  defp print_orchestrator_decisions([]), do: IO.puts("decisions: none")

  defp print_orchestrator_decisions(decisions) do
    rows =
      Enum.map(decisions, fn decision ->
        [
          decision.id,
          decision.status,
          decision.safety,
          decision.action,
          decision.ref,
          Map.get(decision, :state, ""),
          Map.get(decision, :prompt_status, ""),
          decision |> Map.get(:event_ids, []) |> Enum.join(",") |> truncate(32),
          truncate(decision.reason, 88),
          truncate(Map.get(decision, :message, ""), 72)
        ]
      end)

    IO.puts("decisions")

    print_table(
      [
        "ID",
        "STATUS",
        "SAFETY",
        "ACTION",
        "REF",
        "STATE",
        "PROMPT",
        "EVENTS",
        "REASON",
        "MESSAGE"
      ],
      rows
    )
  end

  defp print_operation_execution(%{mode: "dry-run"}), do: IO.puts("execution: dry-run")

  defp print_operation_execution(execution) do
    rows =
      (execution.executed ++ execution.skipped)
      |> Enum.map(fn result ->
        [
          result.status,
          result.id,
          result.action || "",
          result.safety || "",
          Map.get(result, :ref, ""),
          truncate(Map.get(result, :target, ""), 64),
          truncate(operation_execution_result(result), 96)
        ]
      end)

    IO.puts("execution #{execution.requested}")

    if rows == [] do
      IO.puts("no matching actions")
    else
      print_table(["STATUS", "ID", "ACTION", "SAFETY", "REF", "TARGET", "RESULT"], rows)
    end
  end

  defp operation_execution_result(%{capture: %{summary: summary}}), do: summary
  defp operation_execution_result(%{result_summary: summary}), do: summary
  defp operation_execution_result(%{error: error}), do: error
  defp operation_execution_result(%{reason: reason}), do: reason
  defp operation_execution_result(_result), do: ""

  defp print_monitor_cursor(cursor) do
    rows = [
      ["consumer", Map.get(cursor, :consumer, "-")],
      ["source", Map.get(cursor, :source, "-")],
      ["last_event_id", Integer.to_string(Map.get(cursor, :last_event_id, 0))],
      ["last_seen_at", format_time(Map.get(cursor, :last_seen_at))],
      ["updated_at", format_time(Map.get(cursor, :updated_at))]
    ]

    print_table(["CURSOR", "VALUE"], rows)
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

  defp print_summary_errors_after([]), do: :ok

  defp print_summary_errors_after(errors) do
    IO.puts("")
    print_summary_errors(errors)
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

  defp json_orchestrate_report(report) do
    %{
      generated_at: format_time(report.generated_at),
      consumer: report.consumer,
      mode: report.mode,
      scan: json_monitor_scan(report.scan),
      inbox: %{
        cursor: json_monitor_cursor(report.inbox.cursor),
        latest_event_id: report.inbox.latest_event_id,
        unread_total: report.inbox.unread_total,
        matching_unread_total: report.inbox.matching_unread_total,
        returned: report.inbox.returned,
        events: Enum.map(report.inbox.events, &json_monitor_event/1)
      },
      decisions: report.decisions,
      action_queue: Map.get(report, :action_queue),
      execution: report.execution,
      heartbeat: Map.get(report, :heartbeat),
      cursor: maybe_json_monitor_cursor(report.cursor),
      errors: Enum.map(report.errors, &json_error/1)
    }
  end

  defp json_monitor_scan(scan) do
    %{
      generated_at: format_time(scan.generated_at),
      observed: scan.observed,
      observation_refresh: scan.observation_refresh,
      sessions_total: scan.sessions_total,
      events_saved: scan.events_saved,
      events: Enum.map(scan.events, &json_monitor_event/1),
      queues_total: scan.queues_total,
      queues: scan.queues,
      watches_total: Map.get(scan, :watches_total, 0),
      watch_updates: scan |> Map.get(:watch_updates, []) |> Enum.map(&json_watch_update/1),
      watch_actions_total: Map.get(scan, :watch_actions_total, 0),
      watch_actions: scan |> Map.get(:watch_actions, []) |> Enum.map(&json_watch_action/1),
      ci_watches_total: Map.get(scan, :ci_watches_total, 0),
      ci_watch_updates:
        scan |> Map.get(:ci_watch_updates, []) |> Enum.map(&json_ci_watch_update/1),
      wake_triggers_total: Map.get(scan, :wake_triggers_total, 0),
      wake_notifications_saved: Map.get(scan, :wake_notifications_saved, 0),
      wake_triggers: scan |> Map.get(:wake_triggers, []) |> Enum.map(&json_wake_trigger_run/1),
      call_handoffs_total: Map.get(scan, :call_handoffs_total, 0),
      call_handoffs: scan |> Map.get(:call_handoffs, []) |> Enum.map(&json_call_handoff/1),
      delegations_total: Map.get(scan, :delegations_total, 0),
      delegations: scan |> Map.get(:delegations, []) |> Enum.map(&json_delegation/1),
      delegation_reviews_total: Map.get(scan, :delegation_reviews_total, 0),
      delegation_reviews: Map.get(scan, :delegation_reviews, []),
      delegation_preflight: Map.get(scan, :delegation_preflight, %{}),
      delegation_timing: Map.get(scan, :delegation_timing, %{}),
      notifications_saved: Map.get(scan, :notifications_saved, 0),
      notifications: scan |> Map.get(:notifications, []) |> Enum.map(&json_notification/1),
      profiles_total: scan.profiles_total,
      profiles: scan.profiles,
      errors: Enum.map(scan.errors, &json_error/1)
    }
  end

  defp json_monitor_event(event) do
    %{
      id: event.id,
      event_id: event.event_id,
      kind: event.kind,
      severity: event.severity,
      ref: event.ref,
      project: event.project,
      session_type: Map.get(event, :session_type),
      session_kind: Map.get(event, :session_kind),
      control_mode: Map.get(event, :control_mode),
      work_state: event.work_state,
      action: event.action,
      summary: event.summary,
      fingerprint: Map.get(event, :fingerprint),
      payload: observation_snapshot(event.payload),
      inserted_at: format_time(event.inserted_at)
    }
  end

  defp json_monitor_cursor(cursor) do
    %{
      consumer: Map.get(cursor, :consumer),
      source: Map.get(cursor, :source),
      last_event_id: Map.get(cursor, :last_event_id, 0),
      last_seen_at: format_time(Map.get(cursor, :last_seen_at)),
      updated_at: format_time(Map.get(cursor, :updated_at))
    }
  end

  defp maybe_json_monitor_cursor(nil), do: nil
  defp maybe_json_monitor_cursor(cursor), do: json_monitor_cursor(cursor)

  defp json_watch_update(update) do
    %{
      watch: json_session_watch(update.watch),
      previous_status: update.previous_status,
      status: update.status,
      changed: update.changed?,
      profile_action: maybe_json_watch_action(Map.get(update, :profile_action)),
      summary: update.summary,
      ref: update.watch.ref
    }
  end

  defp json_ci_watch_update(update) do
    %{
      watch: json_ci_watch(update.watch),
      previous_status: update.previous_status,
      status: update.status,
      changed: update.changed?,
      profile_action: maybe_json_watch_action(Map.get(update, :profile_action)),
      summary: update.summary,
      ref: update.watch.ref,
      digest: update.digest
    }
  end

  defp maybe_json_watch_action(nil), do: nil
  defp maybe_json_watch_action(action), do: json_watch_action(action)

  defp json_watch_action(action) do
    %{
      watch_id: action.watch_id,
      ref: action.ref,
      action: action.action,
      status: action.status,
      prompt_status: Map.get(action, :prompt_status),
      reason: Map.get(action, :reason),
      result_summary: action.result_summary,
      error: Map.get(action, :error)
    }
  end

  defp json_session_watch(watch) do
    %{
      watch_id: watch.watch_id,
      ref: watch.ref,
      status: watch.status,
      mode: watch.mode,
      project: watch.project,
      session_type: watch.session_type,
      session_kind: watch.session_kind,
      goal: watch.goal,
      success_pattern: watch.success_pattern,
      blocker_pattern: watch.blocker_pattern,
      prompt: watch.prompt,
      last_summary: watch.last_summary,
      result_summary: watch.result_summary,
      last_observed_at: format_time(watch.last_observed_at),
      completed_at: format_time(watch.completed_at),
      inserted_at: format_time(watch.inserted_at),
      updated_at: format_time(watch.updated_at)
    }
  end

  defp json_ci_watch(watch) do
    %{
      watch_id: watch.watch_id,
      repo: watch.repo,
      pr_number: watch.pr_number,
      ref: watch.ref,
      project: watch.project,
      status: watch.status,
      mode: watch.mode,
      goal: watch.goal,
      head_sha: Map.get(watch, :head_sha, ""),
      last_head_sha: Map.get(watch, :last_head_sha, ""),
      success_prompt: watch.success_prompt,
      failure_prompt: watch.failure_prompt,
      last_overall: watch.last_overall,
      last_summary: watch.last_summary,
      last_digest: decode_json_text(watch.last_digest),
      last_checked_at: format_time(watch.last_checked_at),
      last_head_checked_at: format_time(Map.get(watch, :last_head_checked_at)),
      completed_at: format_time(watch.completed_at),
      inserted_at: format_time(watch.inserted_at),
      updated_at: format_time(watch.updated_at)
    }
  end

  defp json_wake_trigger_run(run) do
    %{
      status: run.status,
      result: run.result,
      trigger: json_wake_trigger(run.trigger),
      wake: maybe_json_wake_result(run.wake),
      errors: Enum.map(Map.get(run, :errors, []), &json_error/1)
    }
  end

  defp json_wake_trigger(trigger) do
    %{
      trigger_id: trigger.trigger_id,
      name: trigger.name,
      status: trigger.status,
      message: trigger.message,
      project: trigger.project,
      ref: trigger.ref,
      severity: trigger.severity,
      schedule: trigger.schedule,
      every_seconds: trigger.every_seconds,
      next_run_at: format_time(trigger.next_run_at),
      last_run_at: format_time(trigger.last_run_at),
      run_count: trigger.run_count,
      last_result: trigger.last_result,
      inserted_at: format_time(trigger.inserted_at),
      updated_at: format_time(trigger.updated_at)
    }
  end

  defp maybe_json_wake_result(nil), do: nil

  defp maybe_json_wake_result(result) do
    %{
      wake_id: result.wake_id,
      events: Enum.map(result.events, &json_monitor_event/1),
      notifications: Enum.map(result.notifications.notifications, &json_notification/1),
      notifications_saved: result.notifications.saved,
      errors: result.notifications.errors
    }
  end

  defp json_call_handoff(handoff) do
    %{
      handoff_id: handoff.handoff_id,
      surface: handoff.surface,
      status: handoff.status,
      project: handoff.project,
      ref: handoff.ref,
      title: handoff.title,
      summary: handoff.summary,
      operator_input: handoff.operator_input,
      decisions: decode_json_text(handoff.decisions),
      follow_ups: decode_json_text(handoff.follow_ups),
      brief_snapshot: decode_json_text(handoff.brief_snapshot),
      payload: decode_json_text(handoff.payload),
      closed_at: format_time(handoff.closed_at),
      inserted_at: format_time(handoff.inserted_at),
      updated_at: format_time(handoff.updated_at)
    }
  end

  defp json_delegation(delegation) do
    summary = JX.Delegations.delegation_summary(delegation)

    %{
      delegation_id: delegation.delegation_id,
      status: delegation.status,
      priority: delegation.priority,
      project: delegation.project,
      ref: delegation.ref,
      source: delegation.source,
      owner: delegation.owner,
      agent_kind: delegation.agent_kind,
      title: delegation.title,
      brief: delegation.brief,
      context: decode_json_text(delegation.context),
      constraints: decode_json_text(delegation.constraints),
      acceptance: decode_json_text(delegation.acceptance),
      verification: decode_json_text(delegation.verification),
      write_paths: decode_json_text(delegation.write_paths),
      forbidden_paths: decode_json_text(delegation.forbidden_paths),
      lint_warnings: decode_json_text(delegation.lint_warnings),
      evidence: decode_json_text(delegation.evidence),
      residual_risks: decode_json_text(delegation.residual_risks),
      review: summary.review,
      timing: summary.timing,
      integration_status: delegation.integration_status,
      integration_summary: delegation.integration_summary,
      reviewed_by: delegation.reviewed_by,
      reviewed_at: format_time(delegation.reviewed_at),
      worker_summary: delegation.worker_summary,
      artifacts: decode_json_text(delegation.artifacts),
      payload: decode_json_text(delegation.payload),
      claimed_at: format_time(delegation.claimed_at),
      completed_at: format_time(delegation.completed_at),
      inserted_at: format_time(delegation.inserted_at),
      updated_at: format_time(delegation.updated_at)
    }
  end

  defp json_notification(notification) do
    %{
      notification_id: notification.notification_id,
      source_event_id: notification.source_event_id,
      kind: notification.kind,
      severity: notification.severity,
      status: notification.status,
      ref: notification.ref,
      project: notification.project,
      summary: notification.summary,
      payload: operation_execution_snapshot(notification.payload),
      acknowledged_at: format_time(notification.acknowledged_at),
      inserted_at: format_time(notification.inserted_at),
      updated_at: format_time(notification.updated_at)
    }
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

  defp decode_json_text(value) when value in [nil, ""], do: %{}

  defp decode_json_text(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end

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
