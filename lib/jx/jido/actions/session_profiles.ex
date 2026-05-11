defmodule JX.Jido.Actions.SessionProfiles do
  @moduledoc """
  Build session profile reports through the Workspace API.
  """

  use Jido.Action,
    name: "jx_session_profiles",
    description: "Return session intent profiles compared against live observations",
    category: "jx",
    tags: ["sessions", "profiles", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.session_profiles(opts) end, :profiles)
  end
end
