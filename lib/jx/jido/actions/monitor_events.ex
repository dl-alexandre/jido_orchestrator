defmodule JX.Jido.Actions.MonitorEvents do
  @moduledoc """
  Read monitor events for orchestration catch-up.
  """

  use Jido.Action,
    name: "jx_monitor_events",
    description: "List durable monitor events filtered by ref, kind, severity, or id",
    category: "jx",
    tags: ["monitor", "events", "sessions"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.list_monitor_events(opts) end, :events)
  end
end
