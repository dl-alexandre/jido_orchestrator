defmodule JX.Jido.Actions.PolicyOverview do
  @moduledoc """
  Return current execution policy rules.
  """

  use Jido.Action,
    name: "jx_policy_overview",
    description: "Return commit/push/PR/deploy policy for autonomous orchestration",
    category: "workspace",
    tags: ["policy", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(_params, _context) do
    WorkspaceAction.call(fn -> Workspace.policy_overview() end, :policy)
  end
end
