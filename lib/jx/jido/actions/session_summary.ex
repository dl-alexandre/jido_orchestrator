defmodule JX.Jido.Actions.SessionSummary do
  @moduledoc """
  Build the session summary and recommendation dashboard.
  """

  use Jido.Action,
    name: "jx_session_summary",
    description:
      "Summarize session inventory, observations, recommendations, and remote candidates",
    category: "jx",
    tags: ["sessions", "summary", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.session_summary(opts) end, :summary)
  end
end
