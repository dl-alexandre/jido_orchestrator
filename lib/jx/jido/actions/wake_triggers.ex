defmodule JX.Jido.Actions.WakeTriggers do
  @moduledoc """
  List scheduled wake triggers.
  """

  use Jido.Action,
    name: "jx_wake_triggers",
    description: "Return durable scheduled wake triggers",
    category: "jx",
    tags: ["monitor", "events", "wake", "scheduler", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> {:ok, Workspace.list_wake_triggers(opts)} end, :wake_triggers)
  end
end
