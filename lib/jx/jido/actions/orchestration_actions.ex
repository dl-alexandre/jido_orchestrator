defmodule JX.Jido.Actions.OrchestrationActions do
  @moduledoc """
  List durable orchestration action queue records.
  """

  use Jido.Action,
    name: "jx_orchestration_actions",
    description: "Return durable planned/executed orchestration actions",
    category: "workspace",
    tags: ["orchestration", "actions", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.list_orchestration_actions(opts) end, :actions)
  end
end
