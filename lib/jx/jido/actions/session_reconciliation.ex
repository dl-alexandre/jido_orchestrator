defmodule JX.Jido.Actions.SessionReconciliation do
  @moduledoc """
  Reconcile local session refs with remote tmux observations.
  """

  use Jido.Action,
    name: "jx_session_reconciliation",
    description: "Return local/remote session reconciliation state",
    category: "workspace",
    tags: ["sessions", "remote", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.session_reconciliation(opts) end, :reconciliation)
  end
end
