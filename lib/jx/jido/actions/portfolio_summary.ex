defmodule JX.Jido.Actions.PortfolioSummary do
  @moduledoc """
  Build project-level portfolio summaries through the Workspace API.
  """

  use Jido.Action,
    name: "jx_portfolio_summary",
    description: "Return project and workstream summaries grouped from active session profiles",
    category: "jx",
    tags: ["portfolio", "projects", "sessions", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.portfolio_summary(opts) end, :portfolio)
  end
end
