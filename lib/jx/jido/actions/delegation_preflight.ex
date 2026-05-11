defmodule JX.Jido.Actions.DelegationPreflight do
  @moduledoc """
  Run delegation packet linting and active write ownership checks.
  """

  use Jido.Action,
    name: "jx_delegation_preflight",
    description: "Lint a delegation packet and report active write ownership conflicts",
    category: "jx",
    tags: ["delegation", "orchestration", "safe"],
    schema: [
      delegation_id: [type: :string, required: true, doc: "Delegation id"]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{delegation_id: delegation_id}, _context) do
    WorkspaceAction.call(fn -> Workspace.delegation_preflight(delegation_id) end, :preflight)
  end
end
