defmodule JX.CLI.Events do
  @moduledoc false

  alias JX.MonitorEvents
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @events_check_usage "jx events check [-n 10000] [--json]"
  @events_ls_usage "jx events ls [--since <id>] [--ref <ref>] [--kind <kind>] [--severity info|notice|warning|critical] [-n 20] [--json]"
  @events_unread_usage "jx events unread [--consumer <name>] [--ref <ref>] [--kind <kind>] [--severity info|notice|warning|critical] [-n 20] [--json]"
  @events_ack_usage "jx events ack [--consumer <name>] (--to <id> | --latest) [--json]"
  @events_cursor_usage "jx events cursor [--consumer <name>] [--json]"

  def usage_lines, do: [usage()]

  def usage do
    [
      @events_check_usage,
      @events_ls_usage,
      @events_unread_usage,
      @events_ack_usage,
      @events_cursor_usage
    ]
    |> Enum.join(" | ")
  end

  def run(["check" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [n: :integer, json: :boolean], aliases: [n: :n])

    limit = parsed[:n] || 10_000

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @events_check_usage),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:operational_events_check, [[limit: limit]])
      |> print_events_check(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["ls" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          since: :integer,
          ref: :string,
          kind: :string,
          severity: :string,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @events_ls_usage),
         :ok <- validate_optional_monitor_severity(parsed[:severity]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:list_monitor_events, [
        [
          since_id: parsed[:since],
          ref: parsed[:ref],
          kind: parsed[:kind],
          severity: parsed[:severity],
          limit: limit
        ]
      ])
      |> print_monitor_events(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["unread" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          consumer: :string,
          ref: :string,
          kind: :string,
          severity: :string,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @events_unread_usage),
         :ok <- validate_optional_monitor_severity(parsed[:severity]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts),
         {:ok, report} <-
           apply(workspace(opts), :unread_monitor_events, [
             [
               consumer: parsed[:consumer],
               ref: parsed[:ref],
               kind: parsed[:kind],
               severity: parsed[:severity],
               limit: limit
             ]
           ]) do
      print_monitor_unread(report, json: parsed[:json] || false)

      :ok
    end
  end

  def run(["ack" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [consumer: :string, to: :integer, latest: :boolean, json: :boolean]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @events_ack_usage),
         :ok <- validate_event_ack_opts(parsed[:to], parsed[:latest] || false),
         :ok <- validate_optional_non_negative("to", parsed[:to]),
         :ok <- start_app(opts),
         {:ok, cursor} <-
           apply(workspace(opts), :acknowledge_monitor_events, [
             [
               consumer: parsed[:consumer],
               to_id: parsed[:to]
             ]
           ]) do
      print_monitor_ack(cursor, json: parsed[:json] || false)

      :ok
    end
  end

  def run(["cursor" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [consumer: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @events_cursor_usage),
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

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp validate_non_negative(_name, value) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative(name, _value), do: {:error, "#{name} must be a non-negative integer"}

  defp validate_optional_non_negative(_name, nil), do: :ok
  defp validate_optional_non_negative(name, value), do: validate_non_negative(name, value)

  defp validate_optional_monitor_severity(nil), do: :ok

  defp validate_optional_monitor_severity(severity) do
    severities = MonitorEvents.Event.severities()

    if severity in severities do
      :ok
    else
      {:error,
       "unsupported monitor severity #{inspect(severity)}; expected one of: #{Enum.join(severities, ", ")}"}
    end
  end

  defp validate_event_ack_opts(nil, false),
    do: {:error, "jx events ack requires --to <id> or --latest"}

  defp validate_event_ack_opts(to_id, true) when not is_nil(to_id),
    do: {:error, "jx events ack accepts either --to <id> or --latest, not both"}

  defp validate_event_ack_opts(_to_id, _latest), do: :ok

  defp print_events_check(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("operational event check: #{report.status}")
      IO.puts("checked: #{format_time(report.checked_at)}")
      IO.puts("events: #{report.events}")
      print_summary_counts("rebuilt", report.rebuilt)

      print_summary_counts(
        "queue",
        Map.take(report.queue, [:open_approvals, :planned_actions, :active_leases])
      )

      if report.issues == [] do
        IO.puts("")
        IO.puts("issues: none")
      else
        rows =
          Enum.map(report.issues, fn issue ->
            [
              issue.severity,
              issue.problem,
              blank_to_dash(issue.id),
              "#{issue.entity_type}:#{issue.entity_id}",
              truncate(issue.summary, 72),
              truncate(issue.next, 72)
            ]
          end)

        IO.puts("")
        print_table(["SEVERITY", "PROBLEM", "ID", "ENTITY", "SUMMARY", "NEXT"], rows)
      end

      unless report.next == [] do
        IO.puts("")
        IO.puts("next")
        Enum.each(report.next, &IO.puts("  - #{&1}"))
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

  defp print_monitor_unread(report, opts) do
    if opts[:json] do
      print_json(json_monitor_unread(report))
    else
      print_summary_counts("events", %{
        unread: report.unread_total,
        matching_unread: report.matching_unread_total,
        returned: report.returned,
        latest_event: report.latest_event_id
      })

      IO.puts("")
      print_monitor_cursor(report.cursor)

      IO.puts("")
      print_monitor_events(report.events, json: false)
    end
  end

  defp print_monitor_ack(cursor, opts) do
    if opts[:json] do
      print_json(%{cursor: json_monitor_cursor(cursor)})
    else
      IO.puts("acknowledged #{cursor.consumer} through event #{cursor.last_event_id}")
      print_monitor_cursor(cursor)
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

  defp json_monitor_event(event) do
    %{
      id: event.id,
      event_id: event.event_id,
      kind: event.kind,
      severity: event.severity,
      ref: event.ref,
      project: event.project,
      session_type: event.session_type,
      session_kind: event.session_kind,
      control_mode: event.control_mode,
      work_state: event.work_state,
      action: event.action,
      summary: event.summary,
      fingerprint: event.fingerprint,
      payload: observation_snapshot(event.payload),
      inserted_at: format_time(event.inserted_at)
    }
  end

  defp json_monitor_unread(report) do
    %{
      consumer: report.consumer,
      cursor: json_monitor_cursor(report.cursor),
      latest_event_id: report.latest_event_id,
      unread_total: report.unread_total,
      matching_unread_total: report.matching_unread_total,
      returned: report.returned,
      events: Enum.map(report.events, &json_monitor_event/1)
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

  defp observation_snapshot(snapshot) do
    case Jason.decode(snapshot) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> snapshot
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
