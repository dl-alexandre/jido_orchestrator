defmodule JX.Jido.Actions.MonitorEventStatus do
  @moduledoc """
  Report a durable monitor event cursor and its current lag.
  """

  use Jido.Action,
    name: "jx_monitor_event_status",
    description: "Show monitor event cursor status for a named consumer",
    category: "jx",
    tags: ["monitor", "events", "sessions", "cursor"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.monitor_event_status(opts) end, :status)
  end
end
