defmodule JX.Jido.Actions.AcknowledgeMonitorEvents do
  @moduledoc """
  Advance a durable monitor event cursor for an orchestration consumer.
  """

  use Jido.Action,
    name: "jx_acknowledge_monitor_events",
    description: "Acknowledge monitor events through a specific id or the latest event",
    category: "jx",
    tags: ["monitor", "events", "sessions", "cursor"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.acknowledge_monitor_events(opts) end, :cursor)
  end
end
