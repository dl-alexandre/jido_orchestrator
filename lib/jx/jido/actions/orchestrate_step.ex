defmodule JX.Jido.Actions.OrchestrateStep do
  @moduledoc """
  Run one event-driven orchestration step.
  """

  use Jido.Action,
    name: "jx_orchestrate_step",
    description:
      "Scan sessions, read unread monitor events, plan decisions, optionally execute and ack",
    category: "jx",
    tags: ["monitor", "events", "sessions", "orchestrator"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.orchestrate(opts) end, :orchestration)
  end
end
