defmodule JX.Jido.Actions.Notifications do
  @moduledoc """
  List orchestration notifications.
  """

  use Jido.Action,
    name: "jx_notifications",
    description: "Return unread or historical orchestration notifications",
    category: "workspace",
    tags: ["orchestration", "notifications", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.list_notifications(opts) end, :notifications)
  end
end
