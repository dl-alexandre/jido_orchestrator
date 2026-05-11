defmodule JX.Jido.Actions.Delegations do
  @moduledoc """
  List durable worker-agent delegation packets.
  """

  use Jido.Action,
    name: "jx_delegations",
    description: "Return durable delegation packets for bounded worker-agent work",
    category: "jx",
    tags: ["delegation", "orchestration", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(
      fn -> {:ok, JX.Workspace.list_delegations(opts)} end,
      :delegations
    )
  end
end
