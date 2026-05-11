defmodule JX.Jido.Actions.CallBrief do
  @moduledoc """
  Build a compact call/meeting brief through the Workspace API.
  """

  use Jido.Action,
    name: "jx_call_brief",
    description: "Return a compact call or meeting brief for operator handoff",
    category: "jx",
    tags: ["call", "brief", "portfolio", "orchestrator", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.call_brief(opts) end, :brief)
  end
end
