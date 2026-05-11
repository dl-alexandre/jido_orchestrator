defmodule JX.Jido.Actions.DelegationBrief do
  @moduledoc """
  Render a worker-ready delegation packet.
  """

  use Jido.Action,
    name: "jx_delegation_brief",
    description: "Render the compact prompt packet for a durable delegation",
    category: "jx",
    tags: ["delegation", "orchestration", "safe"],
    schema: [
      delegation_id: [type: :string, required: true, doc: "Delegation id"]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{delegation_id: delegation_id}, _context) do
    WorkspaceAction.call(fn -> Workspace.delegation_brief(delegation_id) end, :brief)
  end
end
