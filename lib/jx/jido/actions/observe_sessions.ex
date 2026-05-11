defmodule JX.Jido.Actions.ObserveSessions do
  @moduledoc """
  Capture and persist current session observations through the Workspace API.
  """

  use Jido.Action,
    name: "jx_observe_sessions",
    description: "Capture current sessions and save observations",
    category: "jx",
    tags: ["sessions", "observe", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.observe_sessions(opts) end, :observation_report)
  end
end
