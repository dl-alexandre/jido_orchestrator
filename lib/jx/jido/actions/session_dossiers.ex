defmodule JX.Jido.Actions.SessionDossiers do
  @moduledoc """
  Build compact current dossiers for active sessions through the Workspace API.
  """

  use Jido.Action,
    name: "jx_session_dossiers",
    description: "Return agent-oriented session dossiers from live state and journals",
    category: "jx",
    tags: ["sessions", "dossiers", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.session_dossiers(opts) end, :dossiers)
  end
end
