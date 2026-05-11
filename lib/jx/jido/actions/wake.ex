defmodule JX.Jido.Actions.Wake do
  @moduledoc """
  Record an immediate external wake event.
  """

  use Jido.Action,
    name: "jx_wake",
    description: "Record an external wake event and notification",
    category: "jx",
    tags: ["monitor", "events", "wake", "safe"],
    schema: [
      message: [type: :string, required: true, doc: "Wake message"],
      project: [type: :string, default: "", doc: "Optional project label"],
      ref: [type: :string, default: "", doc: "Optional session or work reference"],
      severity: [
        type: {:in, ["info", "notice", "warning", "critical"]},
        default: "warning",
        doc: "Monitor severity"
      ]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(params, _context) do
    WorkspaceAction.call(
      fn ->
        Workspace.wake(%{
          message: params.message,
          project: params.project,
          ref: params.ref,
          severity: params.severity,
          source: "jido-action"
        })
      end,
      :wake
    )
  end
end
