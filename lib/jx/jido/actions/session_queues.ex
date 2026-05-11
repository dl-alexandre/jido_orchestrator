defmodule JX.Jido.Actions.SessionQueues do
  @moduledoc """
  Build orchestration queues from session dossiers through the Workspace API.
  """

  use Jido.Action,
    name: "jx_session_queues",
    description: "Return grouped orchestration queues from active session dossiers",
    category: "jx",
    tags: ["sessions", "queues", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.session_queues(opts) end, :queues)
  end
end
