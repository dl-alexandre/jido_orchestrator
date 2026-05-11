defmodule JX.Jido.Actions.SessionWatches do
  @moduledoc """
  List durable session watches through the Workspace API.
  """

  use Jido.Action,
    name: "jx_session_watches",
    description: "Return durable background watch contracts for managed sessions",
    category: "jx",
    tags: ["sessions", "watches", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.list_watches(opts) end, :watches)
  end
end
