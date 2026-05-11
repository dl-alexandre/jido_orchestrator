defmodule JX.Jido.Actions.WorkBoard do
  @moduledoc """
  Build the operator work board through the Workspace API.
  """

  use Jido.Action,
    name: "jx_work_board",
    description: "Return current work items, allowed actions, and repo health",
    category: "jx",
    tags: ["sessions", "work", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.work_board(opts) end, :board)
  end
end
