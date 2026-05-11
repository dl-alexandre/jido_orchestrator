defmodule JX.Jido.Actions.HandleMonitorScan do
  @moduledoc """
  Fold monitor scan lifecycle signals into the supervised orchestrator state.
  """

  use Jido.Action,
    name: "jx_handle_monitor_scan",
    description: "Update orchestrator agent state from monitor scan lifecycle signals",
    category: "jx",
    tags: ["orchestrator", "monitor", "sensor", "safe"],
    schema: [
      status: [type: :string, default: ""],
      generated_at: [type: :string, default: ""],
      scan_total: [type: :integer, default: 0],
      sessions_total: [type: :integer, default: 0],
      events_saved: [type: :integer, default: 0],
      errors_total: [type: :integer, default: 0],
      error: [type: :string, default: ""]
    ]

  @impl true
  def run(params, context) do
    status = field(params, :status)
    state = Map.get(context, :state, %{})

    {:ok,
     %{
       status: agent_status(status),
       scan_total: scan_total(params, state),
       last_scan_status: status,
       last_scan_at: field(params, :generated_at),
       last_scan_sessions_total: integer(params, :sessions_total),
       last_scan_events_saved: integer(params, :events_saved),
       last_scan_errors_total: integer(params, :errors_total),
       last_scan_error: field(params, :error),
       last_error: if(status == "failed", do: field(params, :error), else: "")
     }}
  end

  defp agent_status("failed"), do: :failed
  defp agent_status(_status), do: :scan_observed

  defp scan_total(params, state) do
    case integer(params, :scan_total) do
      0 -> integer(state, :scan_total) + 1
      total -> total
    end
  end

  defp integer(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp field(params, key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key)) || ""
  end
end
