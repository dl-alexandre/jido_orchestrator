defmodule JX.Jido.Actions.CiWatches do
  @moduledoc """
  List durable GitHub Actions PR watches.
  """

  use Jido.Action,
    name: "jx_ci_watches",
    description: "Return durable CI watches used by the background orchestrator",
    tags: ["ci", "github", "orchestration", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> {:ok, Workspace.list_ci_watches(opts)} end, :ci_watches)
  end
end
