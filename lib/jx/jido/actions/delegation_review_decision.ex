defmodule JX.Jido.Actions.DelegationReviewDecision do
  @moduledoc """
  Record a foreground integration decision for a completed delegation.
  """

  use Jido.Action,
    name: "jx_delegation_review_decision",
    description: "Mark a delegation review accepted, revision-requested, rejected, or held",
    category: "jx",
    tags: ["delegation", "review", "gated"],
    schema: [
      delegation_id: [type: :string, required: true, doc: "Delegation id"],
      decision: [type: :string, required: true, doc: "accept, revise, reject, or hold"],
      summary: [type: :string, default: ""],
      reviewer: [type: :string, default: ""]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{delegation_id: delegation_id, decision: decision} = params, _context) do
    attrs = Map.take(params, [:summary, :reviewer])

    WorkspaceAction.call(
      fn -> Workspace.decide_delegation_review(delegation_id, decision, attrs) end,
      :delegation
    )
  end
end
