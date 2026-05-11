defmodule JX.Jido.Actions.CloseCallHandoff do
  @moduledoc """
  Close a durable call or meeting handoff through the Workspace API.
  """

  use Jido.Action,
    name: "jx_close_call_handoff",
    description: "Close an open call or meeting handoff",
    category: "jx",
    tags: ["call", "handoff", "safe"],
    schema: [
      handoff_id: [type: :string, required: true, doc: "Call handoff id"],
      summary: [type: :string, default: "", doc: "Closure summary"]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{handoff_id: handoff_id, summary: summary}, _context) do
    WorkspaceAction.call(fn -> Workspace.close_call_handoff(handoff_id, summary) end, :handoff)
  end
end
