defmodule JX.Jido.Actions.CallHandoffs do
  @moduledoc """
  List durable call and meeting handoffs through the Workspace API.
  """

  use Jido.Action,
    name: "jx_call_handoffs",
    description: "List durable call or meeting handoffs",
    category: "jx",
    tags: ["call", "handoff", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.list_call_handoffs(opts) end, :handoffs)
  end
end
