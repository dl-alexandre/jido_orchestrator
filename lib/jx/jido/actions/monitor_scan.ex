defmodule JX.Jido.Actions.MonitorScan do
  @moduledoc """
  Run a monitor scan and persist deduplicated monitor events.
  """

  use Jido.Action,
    name: "jx_monitor_scan",
    description: "Observe sessions, update queues/profiles, and record monitor events",
    category: "jx",
    tags: ["monitor", "events", "sessions"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.monitor_scan(opts) end, :scan)
  end
end
