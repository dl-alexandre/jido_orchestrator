defmodule JX.CLI.Monitor do
  @moduledoc false

  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @monitor_usage "jx monitor scan|run|start [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--prompt-status none|draft|ready|sent|blocked] [--no-observe] [--lines 40] [--scan-limit 100] [--queue-limit 5] [--event-limit 20] [--interval-ms 30000] [--iterations 0] [--json]"
  @status_usage "jx monitor status [--consumer <name>] [--json]"

  def usage_lines, do: [@monitor_usage, @status_usage]
  def usage, do: Enum.join(usage_lines(), " | ")

  def run([command | args], opts) when command in ["scan", "run", "start"] do
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
          prompt_status: :string,
          observe: :boolean,
          lines: :integer,
          scan_limit: :integer,
          queue_limit: :integer,
          event_limit: :integer,
          interval_ms: :integer,
          iterations: :integer,
          json: :boolean
        ]
      )

    lines = parsed[:lines] || 40
    scan_limit = parsed[:scan_limit] || 100
    queue_limit = parsed[:queue_limit] || 5
    event_limit = parsed[:event_limit] || 20
    interval_ms = parsed[:interval_ms] || 30_000
    iterations = parsed[:iterations] || if(command == "scan", do: 1, else: 0)

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @monitor_usage),
         :ok <- validate_optional_session_type(parsed[:type]),
         :ok <- validate_optional_work_state(parsed[:work_state]),
         :ok <- validate_optional_work_board_control(parsed[:control]),
         :ok <- validate_optional_prompt_status(parsed[:prompt_status]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("queue-limit", queue_limit),
         :ok <- validate_positive("event-limit", event_limit),
         :ok <- validate_positive("interval-ms", interval_ms),
         :ok <- validate_non_negative("iterations", iterations),
         :ok <- start_app(opts) do
      monitor_opts = [
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
        event_limit: event_limit
      ]

      run_monitor(command, monitor_opts, iterations, interval_ms,
        workspace: workspace(opts),
        json: parsed[:json] || false
      )
    end
  end

  def run(["status" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [consumer: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @status_usage),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:monitor_event_status, [[consumer: parsed[:consumer]]])
      |> print_monitor_event_status(json: parsed[:json] || false)

      :ok
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

  defp run_monitor("scan", opts, _iterations, _interval_ms, run_opts) do
    with {:ok, scan} <- apply(run_opts[:workspace], :monitor_scan, [opts]) do
      print_monitor_scan(scan, run_opts)
      :ok
    end
  end

  defp run_monitor(command, opts, iterations, interval_ms, run_opts)
       when command in ["run", "start"] do
    monitor_loop(opts, iterations, interval_ms, run_opts, 1)
  end

  defp monitor_loop(_opts, iterations, _interval_ms, _run_opts, iteration)
       when iterations > 0 and iteration > iterations,
       do: :ok

  defp monitor_loop(opts, iterations, interval_ms, run_opts, iteration) do
    with {:ok, scan} <- apply(run_opts[:workspace], :monitor_scan, [opts]) do
      IO.puts("monitor iteration #{iteration}")
      print_monitor_scan(scan, run_opts)

      if iterations == 0 or iteration < iterations do
        Process.sleep(interval_ms)
        monitor_loop(opts, iterations, interval_ms, run_opts, iteration + 1)
      else
        :ok
      end
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

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp validate_non_negative(_name, value) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative(name, _value), do: {:error, "#{name} must be a non-negative integer"}

  defp print_monitor_scan(scan, opts) do
    if opts[:json] do
      print_json(json_monitor_scan(scan))
    else
      print_summary_counts("monitor", %{
        sessions: scan.sessions_total,
        events_saved: scan.events_saved,
        queues: scan.queues_total,
        watches: Map.get(scan, :watches_total, 0),
        watch_actions: Map.get(scan, :watch_actions_total, 0),
        ci_watches: Map.get(scan, :ci_watches_total, 0),
        delegations: Map.get(scan, :delegations_total, 0),
        delegation_reviews: Map.get(scan, :delegation_reviews_total, 0),
        delegation_long_running: get_in(scan, [:delegation_timing, :active, :long_running]) || 0,
        delegation_conflicts: get_in(scan, [:delegation_preflight, :conflicts_total]) || 0,
        notifications: Map.get(scan, :notifications_saved, 0),
        profiles: scan.profiles_total
      })

      IO.puts("")
      print_summary_counts("observation refresh", scan.observation_refresh)

      unless scan.events == [] do
        IO.puts("")
        IO.puts("new events")
        print_monitor_events(scan.events, json: false)
      end

      unless scan.queues == [] do
        IO.puts("")
        IO.puts("queues")
        print_monitor_queue_rows(scan.queues)
      end

      print_optional_watch_updates(scan)
      print_optional_notifications(scan)
      print_summary_errors_after(scan.errors)
    end
  end

  defp print_optional_watch_updates(scan) do
    watch_updates = Map.get(scan, :watch_updates, [])
    watch_actions = Map.get(scan, :watch_actions, [])
    ci_watch_updates = Map.get(scan, :ci_watch_updates, [])

    unless watch_updates == [] do
      IO.puts("")
      IO.puts("watch updates")
      print_watch_updates(watch_updates)
    end

    unless watch_actions == [] do
      IO.puts("")
      IO.puts("watch actions")
      print_watch_actions(watch_actions)
    end

    unless ci_watch_updates == [] do
      IO.puts("")
      IO.puts("CI watch updates")
      print_ci_watch_updates(ci_watch_updates)
    end
  end

  defp print_optional_notifications(scan) do
    notifications = Map.get(scan, :notifications, [])

    unless notifications == [] do
      IO.puts("")
      IO.puts("notifications")
      print_notifications(notifications, json: false)
    end
  end

  defp print_monitor_event_status(status, opts) do
    if opts[:json] do
      print_json(json_monitor_event_status(status))
    else
      rows = [
        ["consumer", status.consumer],
        ["cursor_source", Map.get(status.cursor, :source, "-")],
        ["last_event_id", Integer.to_string(Map.get(status.cursor, :last_event_id, 0))],
        ["latest_event_id", Integer.to_string(status.latest_event_id)],
        ["unread_total", Integer.to_string(status.unread_total)],
        ["caught_up", inspect(status.caught_up)],
        ["last_seen_at", format_time(Map.get(status.cursor, :last_seen_at))],
        ["updated_at", format_time(Map.get(status.cursor, :updated_at))]
      ]

      print_table(["FIELD", "VALUE"], rows)

      if status.latest_event do
        IO.puts("")
        IO.puts("latest event")
        print_monitor_events([status.latest_event], json: false)
      end
    end
  end

  defp print_monitor_events([], opts) do
    if opts[:json] do
      print_json(%{events: []})
    else
      IO.puts("no monitor events")
    end
  end

  defp print_monitor_events(events, opts) do
    if opts[:json] do
      print_json(%{events: Enum.map(events, &json_monitor_event/1)})
    else
      rows =
        Enum.map(events, fn event ->
          [
            Integer.to_string(event.id),
            format_time(event.inserted_at),
            event.kind,
            event.severity,
            event.ref,
            event.project,
            event.work_state,
            event.action,
            truncate(event.summary, 120)
          ]
        end)

      print_table(
        ["ID", "TIME", "KIND", "SEVERITY", "REF", "PROJECT", "WORK", "ACTION", "SUMMARY"],
        rows
      )
    end
  end

  defp print_monitor_queue_rows(queues) do
    rows =
      Enum.map(queues, fn queue ->
        [
          queue.action,
          Integer.to_string(queue.total),
          format_counts(queue.by_priority),
          format_counts(queue.by_safety),
          format_counts(queue.by_control),
          session_queue_refs(queue),
          session_queue_focus(queue)
        ]
      end)

    print_table(["ACTION", "TOTAL", "PRIORITY", "SAFETY", "CONTROL", "REFS", "FOCUS"], rows)
  end

  defp print_watch_updates(updates) do
    rows =
      Enum.map(updates, fn update ->
        [
          update.watch.watch_id,
          update.previous_status,
          update.status,
          update.watch.mode,
          update.watch.ref,
          truncate(update.watch.goal, 44),
          truncate(update.summary, 72)
        ]
      end)

    print_table(["WATCH", "FROM", "TO", "MODE", "REF", "GOAL", "SUMMARY"], rows)
  end

  defp print_watch_actions(actions) do
    rows =
      Enum.map(actions, fn action ->
        [
          action.watch_id,
          action.status,
          action.action,
          action.ref,
          Map.get(action, :prompt_status, ""),
          truncate(Map.get(action, :reason, ""), 40),
          truncate(action.result_summary, 72)
        ]
      end)

    print_table(["WATCH", "STATUS", "ACTION", "REF", "PROMPT", "REASON", "SUMMARY"], rows)
  end

  defp print_ci_watch_updates(updates) do
    rows =
      Enum.map(updates, fn update ->
        [
          update.watch.watch_id,
          update.previous_status,
          update.status,
          update.watch.mode,
          update.watch.repo,
          "##{update.watch.pr_number}",
          update.watch.ref,
          truncate(update.summary, 72)
        ]
      end)

    print_table(["WATCH", "FROM", "TO", "MODE", "REPO", "PR", "REF", "SUMMARY"], rows)
  end

  defp print_notifications([], opts) do
    if opts[:json], do: print_json(%{notifications: []}), else: IO.puts("no notifications")
  end

  defp print_notifications(notifications, opts) do
    if opts[:json] do
      print_json(%{notifications: Enum.map(notifications, &json_notification/1)})
    else
      rows =
        Enum.map(notifications, fn notification ->
          [
            notification.notification_id,
            notification.status,
            notification.severity,
            notification.ref,
            notification.project,
            notification.kind,
            truncate(notification.summary, 96),
            format_time(notification.inserted_at)
          ]
        end)

      print_table(["ID", "STATUS", "SEVERITY", "REF", "PROJECT", "KIND", "SUMMARY", "AT"], rows)
    end
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

  defp json_monitor_event_status(status) do
    %{
      consumer: status.consumer,
      cursor: json_monitor_cursor(status.cursor),
      latest_event_id: status.latest_event_id,
      unread_total: status.unread_total,
      caught_up: status.caught_up,
      latest_event: maybe_json_monitor_event(status.latest_event)
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

  defp maybe_json_monitor_event(nil), do: nil
  defp maybe_json_monitor_event(event), do: json_monitor_event(event)

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

  defp session_queue_refs(%{items: items}) do
    items
    |> Enum.map(& &1.ref)
    |> Enum.join(",")
    |> truncate(72)
  end

  defp session_queue_focus(%{items: []}), do: ""

  defp session_queue_focus(%{items: [item | _rest]}) do
    first_present([item.task, item.current_path, item.pane])
    |> truncate(96)
  end

  defp first_present(values) do
    Enum.find_value(values, "", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end)
  end

  defp format_counts(counts) when counts == %{}, do: ""

  defp format_counts(counts) do
    counts
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> "#{key}:#{value}" end)
    |> Enum.join(",")
  end

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
