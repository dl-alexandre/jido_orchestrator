defmodule JX.Jido.Actions.DelegationReviews do
  @moduledoc """
  List foreground integration review cards for completed delegations.
  """

  use Jido.Action,
    name: "jx_delegation_reviews",
    description:
      "List completed delegation review cards awaiting foreground integration decisions",
    category: "jx",
    tags: ["delegation", "review", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> {:ok, Workspace.delegation_reviews(opts)} end, :reviews)
  end
end
