defmodule JX.Jido.Actions.ApplyCallHandoff do
  @moduledoc """
  Apply a durable call or meeting handoff through the Workspace API.
  """

  use Jido.Action,
    name: "jx_apply_call_handoff",
    description: "Convert a call handoff into a prompt, watch, or hold action",
    category: "jx",
    tags: ["call", "handoff", "orchestration", "gated"],
    schema: [
      handoff_id: [type: :string, required: true, doc: "Call handoff id"],
      action: [type: {:in, ["prompt", "watch", "hold"]}, required: true],
      ref: [type: :string, required: true, doc: "Target session ref"],
      message: [type: :string, default: "", doc: "Prompt message for prompt action"],
      prompt_status: [type: {:in, ["ready", "draft"]}, default: "ready"],
      reason: [type: :string, default: "", doc: "Hold reason for hold action"],
      goal: [type: :string, default: "", doc: "Watch goal"],
      success_pattern: [type: :string, default: "", doc: "Watch success pattern"],
      blocker_pattern: [type: :string, default: "", doc: "Watch blocker pattern"],
      mode: [type: {:in, ["notify", "hold", "prompt"]}, default: "notify"],
      prompt: [
        type: :string,
        default: "",
        doc: "Prompt to chamber when prompt-mode watch succeeds"
      ],
      summary: [type: :string, default: "", doc: "Apply summary"]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(params, _context) do
    attrs = %{
      action: params.action,
      ref: params.ref,
      message: params.message,
      prompt_status: params.prompt_status,
      reason: params.reason,
      goal: params.goal,
      success_pattern: params.success_pattern,
      blocker_pattern: params.blocker_pattern,
      mode: params.mode,
      prompt: params.prompt,
      summary: params.summary
    }

    WorkspaceAction.call(fn -> Workspace.apply_call_handoff(params.handoff_id, attrs) end, :apply)
  end
end
