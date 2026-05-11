defmodule JX.Jido.Actions.MonitorUnreadEvents do
  @moduledoc """
  Read unread monitor events for a durable orchestration consumer.
  """

  use Jido.Action,
    name: "jx_monitor_unread_events",
    description: "Read monitor events after a named consumer cursor",
    category: "jx",
    tags: ["monitor", "events", "sessions", "cursor"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.unread_monitor_events(opts) end, :unread)
  end
end
