defmodule JX.Jido.Actions.DelegationReview do
  @moduledoc """
  Build a foreground integration review card for a delegation.
  """

  use Jido.Action,
    name: "jx_delegation_review",
    description: "Review completed worker output against ownership, evidence, and risks",
    category: "jx",
    tags: ["delegation", "review", "safe"],
    schema: [
      delegation_id: [type: :string, required: true, doc: "Delegation id"]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{delegation_id: delegation_id}, _context) do
    WorkspaceAction.call(fn -> Workspace.delegation_review(delegation_id) end, :review)
  end
end
