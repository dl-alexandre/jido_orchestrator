defmodule JX.Jido.Actions.DelegationEvidence do
  @moduledoc """
  Attach structured verification evidence to a delegation.
  """

  use Jido.Action,
    name: "jx_delegation_evidence",
    description: "Record exact command evidence for a worker delegation",
    category: "jx",
    tags: ["delegation", "evidence", "safe"],
    schema: [
      delegation_id: [type: :string, required: true, doc: "Delegation id"],
      command: [type: :string, required: true, doc: "Exact command that was run"],
      cwd: [type: :string, required: true, doc: "Working directory for the command"],
      exit_status: [type: :integer, required: true, doc: "Process exit status"],
      kind: [type: :string, default: "command"],
      output_excerpt: [type: :string, default: ""],
      artifacts: [type: {:list, :string}, default: []],
      risks: [type: {:list, :string}, default: []]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{delegation_id: delegation_id} = params, _context) do
    attrs =
      Map.take(params, [
        :command,
        :cwd,
        :exit_status,
        :kind,
        :output_excerpt,
        :artifacts,
        :risks
      ])

    WorkspaceAction.call(
      fn -> Workspace.add_delegation_evidence(delegation_id, attrs) end,
      :delegation
    )
  end
end
