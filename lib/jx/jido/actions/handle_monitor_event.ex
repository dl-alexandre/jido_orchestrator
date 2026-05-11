defmodule JX.Jido.Actions.HandleMonitorEvent do
  @moduledoc """
  Fold monitor-event signals into the supervised orchestrator agent state.

  The durable journal remains `JX.MonitorEvents`. This action gives the
  live Jido agent an event-driven view of that journal without re-querying the
  database for every inserted event.
  """

  use Jido.Action,
    name: "jx_handle_monitor_event",
    description: "Update orchestrator agent state from a monitor-event signal",
    category: "jx",
    tags: ["orchestrator", "monitor", "signals", "safe"],
    schema: [
      event_id: [type: :string, default: ""],
      kind: [type: :string, default: ""],
      severity: [type: :string, default: "info"],
      ref: [type: :string, default: ""],
      project: [type: :string, default: ""],
      summary: [type: :string, default: ""]
    ]

  @impl true
  def run(params, context) do
    state = Map.get(context, :state, %{})
    severity = field(params, :severity)

    {:ok,
     %{
       status: status(severity),
       event_total: integer(state, :event_total) + 1,
       warning_event_total: warning_total(state, severity),
       last_event_id: field(params, :event_id),
       last_event_type: field(params, :kind),
       last_event_ref: field(params, :ref),
       last_event_project: field(params, :project),
       last_event_summary: field(params, :summary),
       last_error: ""
     }}
  end

  defp status(severity) when severity in ["warning", "error"], do: :attention
  defp status(_severity), do: :event_seen

  defp warning_total(state, severity) when severity in ["warning", "error"] do
    integer(state, :warning_event_total) + 1
  end

  defp warning_total(state, _severity), do: integer(state, :warning_event_total)

  defp integer(state, key) do
    case Map.get(state, key, 0) do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp field(params, key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key)) || ""
  end
end
