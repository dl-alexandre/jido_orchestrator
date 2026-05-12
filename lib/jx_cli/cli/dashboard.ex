defmodule JX.CLI.Dashboard do
  @moduledoc false

  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @dashboard_usage "jx dashboard [--stale-after-seconds 900] [--events 25] [-n 50] [--json]"
  @dashboard_workspace_usage "jx dashboard workspace <workspace-id> [--stale-after-seconds 900] [--events 25] [--json]"
  @dashboard_runner_usage "jx dashboard runner <runner-id> [--events 25] [-n 100] [--json]"
  @dashboard_assignment_usage "jx dashboard assignment <assignment-id> [--events 25] [-n 100] [--json]"
  @dashboard_action_usage "jx dashboard action <action-id> [--events 25] [-n 100] [--json]"
  @usage_note "Dashboard commands are read-only operational visibility. They expose event-plane projections, existing leases, assignments, runner state, replay evidence, and recovery hints without adding execution authority."

  def usage_lines do
    [
      @dashboard_usage,
      @dashboard_workspace_usage,
      @dashboard_runner_usage,
      @dashboard_assignment_usage,
      @dashboard_action_usage,
      "",
      @usage_note
    ]
  end

  def usage do
    [
      @dashboard_usage,
      @dashboard_workspace_usage,
      @dashboard_runner_usage,
      @dashboard_assignment_usage,
      @dashboard_action_usage
    ]
    |> Enum.join(" | ")
  end

  def run(["workspace", workspace_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [stale_after_seconds: :integer, events: :integer, json: :boolean]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @dashboard_workspace_usage),
         :ok <- validate_optional_positive("stale-after-seconds", parsed[:stale_after_seconds]),
         :ok <- validate_optional_positive("events", parsed[:events]),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:operator_dashboard_workspace, [
        workspace_id,
        [
          stale_after_seconds: parsed[:stale_after_seconds] || 15 * 60,
          event_limit: parsed[:events] || 25
        ]
      ])
      |> print_operator_dashboard_workspace(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["runner", runner_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [n: :integer, events: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 100

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @dashboard_runner_usage),
         :ok <- validate_positive("n", limit),
         :ok <- validate_optional_positive("events", parsed[:events]),
         :ok <- start_app(opts),
         {:ok, report} <-
           apply(workspace(opts), :operator_dashboard_runner, [
             runner_id,
             [limit: limit, event_limit: parsed[:events] || 25]
           ]) do
      print_operator_dashboard_runner(report, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["assignment", assignment_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [n: :integer, events: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 100

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @dashboard_assignment_usage),
         :ok <- validate_positive("n", limit),
         :ok <- validate_optional_positive("events", parsed[:events]),
         :ok <- start_app(opts),
         {:ok, report} <-
           apply(workspace(opts), :operator_dashboard_assignment, [
             assignment_id,
             [limit: limit, event_limit: parsed[:events] || 25]
           ]) do
      print_operator_dashboard_assignment(report, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["action", action_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [n: :integer, events: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 100

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @dashboard_action_usage),
         :ok <- validate_positive("n", limit),
         :ok <- validate_optional_positive("events", parsed[:events]),
         :ok <- start_app(opts),
         {:ok, report} <-
           apply(workspace(opts), :operator_dashboard_action, [
             action_id,
             [limit: limit, event_limit: parsed[:events] || 25]
           ]) do
      print_operator_dashboard_action(report, json: parsed[:json] || false)
      :ok
    end
  end

  def run(args, opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          stale_after_seconds: :integer,
          events: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @dashboard_usage),
         :ok <- validate_positive("n", limit),
         :ok <- validate_optional_positive("events", parsed[:events]),
         :ok <- validate_optional_positive("stale-after-seconds", parsed[:stale_after_seconds]),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:operator_dashboard, [
        [
          limit: limit,
          event_limit: parsed[:events] || 25,
          stale_after_seconds: parsed[:stale_after_seconds] || 15 * 60
        ]
      ])
      |> print_operator_dashboard(json: parsed[:json] || false)

      :ok
    end
  end

  defp workspace(opts), do: Keyword.get(opts, :workspace, Workspace)

  defp start_app(opts) do
    case Keyword.fetch(opts, :start_app) do
      {:ok, start_app} -> start_app.()
      :error -> {:error, :missing_start_app_callback}
    end
  end

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp validate_optional_positive(_name, nil), do: :ok
  defp validate_optional_positive(name, value), do: validate_positive(name, value)

  defp print_operator_dashboard(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("operator dashboard")
      IO.puts("generated: #{format_time(report.generated_at)}")
      IO.puts("source: append-only operational events and existing JX read models")
      IO.puts("authority: visibility only; execution remains in DevIDE safe-action registry")
      IO.puts("")
      print_summary_counts("queue", report.queue.totals)

      print_summary_counts(
        "workspace health",
        Map.take(report.workspaces, [:total, :stale, :blocked])
      )

      print_summary_counts(
        "runner fleet",
        Map.take(report.runner_fleet, [:total, :stale, :busy, :active_sessions])
      )

      print_summary_counts(
        "runtime environments",
        Map.take(report.runtime_environments, [:total, :ready, :assigned, :stale])
      )

      print_summary_counts(
        "leases",
        %{
          total: report.leases.total,
          active: length(report.leases.active),
          stale: length(report.leases.stale),
          terminal: length(report.leases.terminal)
        }
      )

      print_summary_counts(
        "assignments",
        %{
          total: report.assignments.total,
          active: length(report.assignments.active),
          terminal: length(report.assignments.terminal),
          failed: length(report.assignments.failed)
        }
      )

      print_summary_counts(
        "reconciliation",
        Map.take(report.reconciliation, [:total, :pending, :succeeded, :failed])
      )

      print_dashboard_list("failed work", report.failures.assignments, [
        :assignment_id,
        :status,
        :workspace_id,
        :runner_id,
        :summary
      ])

      print_dashboard_events("recent events", report.recent_events)
      print_dashboard_next(report.next)
    end
  end

  defp print_operator_dashboard_workspace(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("workspace dashboard #{report.workspace_id}")
      IO.puts("generated: #{format_time(report.generated_at)}")
      print_summary_counts("health", Map.take(report.health, [:status, :freshness, :risk]))

      print_dashboard_list("approvals", report.approvals, [
        :approval_id,
        :kind,
        :severity,
        :status,
        :freshness,
        :owner
      ])

      print_dashboard_list("safe actions", report.actions, [
        :action_id,
        :action,
        :status,
        :outcome,
        :owner
      ])

      print_dashboard_list("assignments", report.assignments, [
        :assignment_id,
        :status,
        :runner_id,
        :safe_action_kind,
        :summary
      ])

      print_dashboard_list("runner sessions", report.runner_sessions, [
        :session_id,
        :status,
        :runner_id,
        :assignment_id,
        :last_summary
      ])

      print_dashboard_list("leases", report.leases, [
        :lease_id,
        :resource_type,
        :resource_id,
        :owner,
        :status
      ])

      print_dashboard_events("timeline", report.timeline.events)
      print_dashboard_next(report.next)
    end
  end

  defp print_operator_dashboard_runner(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("runner dashboard #{report.runner_id}")
      IO.puts("generated: #{format_time(report.generated_at)}")

      print_summary_counts(
        "runner",
        Map.take(report.runner, [:status, :host_name, :stale, :active_sessions])
      )

      print_dashboard_list("sessions", report.sessions, [
        :session_id,
        :status,
        :workspace_id,
        :assignment_id,
        :last_summary
      ])

      print_dashboard_list("assignments", report.assignments, [
        :assignment_id,
        :status,
        :workspace_id,
        :action_id,
        :summary
      ])

      print_dashboard_list("reports", report.reports, [
        :report_id,
        :kind,
        :status,
        :assignment_id,
        :summary
      ])

      print_dashboard_events("timeline", report.timeline.events)
      print_dashboard_next(report.next)
    end
  end

  defp print_operator_dashboard_assignment(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("assignment dashboard #{report.assignment_id}")
      IO.puts("generated: #{format_time(report.generated_at)}")

      print_summary_counts(
        "assignment",
        Map.take(report.assignment, [
          :status,
          :workspace_id,
          :action_id,
          :runner_id,
          :session_id,
          :correlation_id
        ])
      )

      print_summary_counts(
        "replay",
        Map.take(report.replay, [:status, :devide_assignment_id, :failure_class])
      )

      print_dashboard_list("assignment reports", report.reports, [
        :report_id,
        :kind,
        :status,
        :agent_id,
        :summary
      ])

      print_dashboard_list("runner reports", report.runner_reports, [
        :report_id,
        :kind,
        :status,
        :runner_id,
        :summary
      ])

      print_dashboard_list("failure chain", report.failure_chain, [
        :kind,
        :status,
        :failure_class,
        :summary
      ])

      print_dashboard_events("timeline", report.timeline.events)
      print_dashboard_next(report.next)
    end
  end

  defp print_operator_dashboard_action(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("safe-action dashboard #{report.action_id}")
      IO.puts("generated: #{format_time(report.generated_at)}")

      print_summary_counts(
        "safe action",
        Map.take(report.action, [:action_id, :safe_action, :status, :outcome, :approval_id])
      )

      if report.approval do
        print_summary_counts(
          "approval",
          Map.take(report.approval, [:approval_id, :status, :kind, :severity])
        )
      end

      print_dashboard_list("execution evidence", report.execution_events, [
        :event_id,
        :kind,
        :status,
        :summary
      ])

      print_dashboard_list("assignments", report.assignments, [
        :assignment_id,
        :status,
        :workspace_id,
        :runner_id,
        :summary
      ])

      print_dashboard_list("reconciliation", report.reconciliation.items, [
        :assignment_id,
        :status,
        :devide_assignment_id,
        :failure_class,
        :last_reconciled_at
      ])

      print_dashboard_events("timeline", report.timeline.events)
      print_dashboard_next(report.next)
    end
  end

  defp print_dashboard_list(label, [], _fields) do
    IO.puts("")
    IO.puts("#{label}: none")
  end

  defp print_dashboard_list(label, items, fields) do
    IO.puts("")
    IO.puts(label)

    rows =
      Enum.map(items, fn item ->
        Enum.map(fields, fn field ->
          item
          |> Map.get(field, "")
          |> dashboard_value()
        end)
      end)

    fields
    |> Enum.map(&(&1 |> Atom.to_string() |> String.upcase()))
    |> print_table(rows)
  end

  defp print_dashboard_events(label, []) do
    IO.puts("")
    IO.puts("#{label}: none")
  end

  defp print_dashboard_events(label, events) do
    print_dashboard_list(label, events, [
      :event_id,
      :kind,
      :severity,
      :entity_type,
      :entity_id,
      :summary
    ])
  end

  defp print_dashboard_next(next) do
    IO.puts("")
    IO.puts("next")

    next
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.each(fn {key, value} ->
      IO.puts("  #{key}: #{value}")
    end)
  end

  defp dashboard_value(%DateTime{} = value), do: format_time(value)

  defp dashboard_value(value) when is_list(value),
    do: Enum.map_join(value, ",", &dashboard_value/1)

  defp dashboard_value(value) when is_map(value), do: Jason.encode!(value)
  defp dashboard_value(value), do: value |> blank_to_dash() |> truncate(80)

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
  defp format_time(value) when is_binary(value), do: if(value == "", do: "-", else: value)

  defp blank_to_dash(value) when value in [nil, ""], do: "-"
  defp blank_to_dash(value), do: to_string(value)

  defp truncate(value, max_length) do
    value = blank_to_dash(value)

    if String.length(value) > max_length do
      String.slice(value, 0, max_length - 1) <> "..."
    else
      value
    end
  end
end
