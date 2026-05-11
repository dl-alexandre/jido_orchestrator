defmodule JX.Jido.Actions.CreateDelegation do
  @moduledoc """
  Create a durable delegation packet for a worker agent.
  """

  use Jido.Action,
    name: "jx_create_delegation",
    description: "Create a bounded problem packet to hand to a worker agent",
    category: "jx",
    tags: ["delegation", "orchestration", "gated"],
    schema: [
      title: [type: :string, required: true, doc: "Short delegation title"],
      brief: [type: :string, required: true, doc: "Concrete worker objective"],
      project: [type: :string, default: ""],
      ref: [type: :string, default: ""],
      owner: [type: :string, default: ""],
      agent_kind: [type: :string, default: "worker"],
      priority: [type: :integer, default: 0],
      context: [type: {:list, :string}, default: []],
      constraints: [type: {:list, :string}, default: []],
      acceptance: [type: {:list, :string}, default: []],
      verification: [type: {:list, :string}, default: []],
      write_paths: [type: {:list, :string}, default: []],
      forbidden_paths: [type: {:list, :string}, default: []]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(params, _context) do
    attrs =
      params
      |> Map.take([
        :title,
        :brief,
        :project,
        :ref,
        :owner,
        :agent_kind,
        :priority,
        :context,
        :constraints,
        :acceptance,
        :verification,
        :write_paths,
        :forbidden_paths
      ])

    WorkspaceAction.call(fn -> Workspace.create_delegation(attrs) end, :delegation)
  end
end
