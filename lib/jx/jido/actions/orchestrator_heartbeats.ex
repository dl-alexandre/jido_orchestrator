defmodule JX.Jido.Actions.OrchestratorHeartbeats do
  @moduledoc """
  List durable orchestrator daemon heartbeats.
  """

  use Jido.Action,
    name: "jx_orchestrator_heartbeats",
    description: "Return durable heartbeat state for background orchestrators",
    category: "workspace",
    tags: ["orchestration", "heartbeat", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.list_orchestrator_heartbeats(opts) end, :heartbeats)
  end
end
