defmodule JX.Jido.Actions.OrchestratorHealth do
  @moduledoc """
  Return daemon heartbeat health alerts and heartbeat context.
  """

  use Jido.Action,
    name: "jx_orchestrator_health",
    description: "Return daemon health alerts derived from orchestrator heartbeats",
    category: "workspace",
    tags: ["orchestration", "heartbeat", "health", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> {:ok, Workspace.orchestrator_health(opts)} end, :health)
  end
end
