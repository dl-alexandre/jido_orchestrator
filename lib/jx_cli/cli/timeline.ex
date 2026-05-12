defmodule JX.CLI.Timeline do
  @moduledoc false

  alias JX.OperationalEvents
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, validate_options: 1]

  @timeline_usage "jx timeline workspace|approval|action|assignment|agent|runner|session <id> [-n 100] [--json]"

  def usage_lines, do: [@timeline_usage]
  def usage, do: @timeline_usage

  def run([scope, id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [n: :integer, json: :boolean], aliases: [n: :n])

    limit = parsed[:n] || 100

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @timeline_usage),
         :ok <- validate_timeline_scope(scope),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:operational_timeline, [scope, id, [limit: limit]])
      |> print_timeline(json: parsed[:json] || false)

      :ok
    end
  end

  def run(_args, _opts), do: {:error, "usage: #{@timeline_usage}"}

  defp workspace(opts), do: Keyword.get(opts, :workspace, Workspace)

  defp start_app(opts) do
    case Keyword.fetch(opts, :start_app) do
      {:ok, start_app} -> start_app.()
      :error -> {:error, :missing_start_app_callback}
    end
  end

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp validate_timeline_scope(scope)
       when scope in ~w(workspace approval action assignment agent runner session),
       do: :ok

  defp validate_timeline_scope(scope),
    do:
      {:error,
       "unsupported timeline scope #{inspect(scope)}; expected workspace, approval, action, assignment, agent, runner, or session"}

  defp print_timeline(timeline, opts) do
    if opts[:json] do
      print_json(%{
        scope: timeline.scope,
        id: timeline.id,
        events: Enum.map(timeline.events, &json_operational_event/1),
        rebuilt: timeline.rebuilt
      })
    else
      IO.puts("timeline #{timeline.scope} #{timeline.id}")

      if timeline.events == [] do
        IO.puts("events: none")
      else
        IO.puts("events")

        Enum.each(timeline.events, fn event ->
          note = timeline_note(event)

          IO.puts(
            "  - #{format_time(event.inserted_at)} #{event.kind} corr=#{event.correlation_id} entity=#{event.entity_type}:#{event.entity_id} owner=#{blank_to_dash(event.owner)} #{event.summary}#{note}"
          )
        end)
      end
    end
  end

  defp timeline_note(event) do
    payload = OperationalEvents.decode_payload(event)

    cond do
      event.kind == "safe_action.execute_denied" ->
        denial = Map.get(payload, "denial", %{})

        " outcome=#{blank_to_dash(Map.get(denial, "outcome"))} reason=#{blank_to_dash(Map.get(denial, "reason"))} next=jx actions show #{event.action_id}"

      event.kind in ["lease.expired", "lease.reassigned"] ->
        " next=jx leases ls --resource #{timeline_lease_resource(payload)} --status all"

      event.kind == "approval.acknowledged" ->
        " next=jx actions history #{event.approval_id}"

      event.kind == "safe_action.executed" ->
        " next=jx actions show #{event.action_id}"

      event.entity_type not in OperationalEvents.Event.entity_types() ->
        " note=unknown_entity_type"

      payload == %{} and event.payload not in [nil, "", "{}"] ->
        " note=payload_unavailable"

      true ->
        ""
    end
  end

  defp timeline_lease_resource(payload) when is_map(payload) do
    type = Map.get(payload, "resource_type", "approval")
    id = Map.get(payload, "resource_id", "")
    "#{type}:#{id}"
  end

  defp timeline_lease_resource(_payload), do: "approval:<id>"

  defp json_operational_event(event) do
    %{
      event_id: event.event_id,
      correlation_id: event.correlation_id,
      source: event.source,
      kind: event.kind,
      entity_type: event.entity_type,
      entity_id: event.entity_id,
      workspace_id: event.workspace_id,
      approval_id: event.approval_id,
      action_id: event.action_id,
      lease_id: event.lease_id,
      owner: event.owner,
      severity: event.severity,
      summary: event.summary,
      payload: OperationalEvents.decode_payload(event),
      inserted_at: event.inserted_at
    }
  end

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value) when is_binary(value), do: if(value == "", do: "-", else: value)

  defp blank_to_dash(value) when value in [nil, ""], do: "-"
  defp blank_to_dash(value), do: to_string(value)
end
