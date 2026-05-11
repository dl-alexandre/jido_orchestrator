defmodule JX.Jido.Actions.RecoveryPlan do
  @moduledoc """
  Return explicit session recovery recommendations.
  """

  use Jido.Action,
    name: "jx_recovery_plan",
    description: "Return reattach, duplicate-session, and corrupt-observation recovery work",
    category: "workspace",
    tags: ["sessions", "recovery", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.recovery_plan(opts) end, :recovery)
  end
end
