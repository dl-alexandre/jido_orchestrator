defmodule JX.Jido.Actions.RunDueWakeTriggers do
  @moduledoc """
  Run due scheduled wake triggers.
  """

  use Jido.Action,
    name: "jx_run_due_wake_triggers",
    description: "Emit due scheduled wake triggers",
    category: "jx",
    tags: ["monitor", "events", "wake", "scheduler", "safe"],
    schema: [
      limit: [type: :integer, default: 20, doc: "Maximum due triggers to run"]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(params, _context) do
    WorkspaceAction.call(
      fn -> Workspace.run_due_wake_triggers(limit: params.limit) end,
      :wake_triggers
    )
  end
end
