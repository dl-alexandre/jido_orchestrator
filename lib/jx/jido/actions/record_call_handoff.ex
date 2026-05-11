defmodule JX.Jido.Actions.RecordCallHandoff do
  @moduledoc """
  Record a durable call or meeting handoff through the Workspace API.
  """

  use Jido.Action,
    name: "jx_record_call_handoff",
    description: "Persist operator decisions and follow-ups from a realtime surface",
    category: "jx",
    tags: ["call", "handoff", "orchestration", "safe"],
    schema: [
      summary: [type: :string, required: true, doc: "Compact handoff summary"],
      title: [type: :string, default: "", doc: "Optional handoff title"],
      surface: [type: {:in, ["call", "phone", "meet", "talk", "chat"]}, default: "call"],
      project: [type: :string, default: "", doc: "Optional project label"],
      ref: [type: :string, default: "", doc: "Optional session ref"],
      operator_input: [type: :string, default: "", doc: "Raw operator note or transcript excerpt"],
      decisions: [type: {:list, :string}, default: [], doc: "Decisions made during the call"],
      follow_ups: [type: {:list, :string}, default: [], doc: "Follow-up work items"],
      opts: [type: :keyword_list, default: [], doc: "Workspace API options"]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(params, _context) do
    attrs = %{
      summary: params.summary,
      title: params.title,
      surface: params.surface,
      project: params.project,
      ref: params.ref,
      operator_input: params.operator_input,
      decisions: params.decisions,
      follow_ups: params.follow_ups
    }

    WorkspaceAction.call(fn -> Workspace.create_call_handoff(attrs, params.opts) end, :handoff)
  end
end
