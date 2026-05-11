defmodule JX.Jido.Actions.ReviewCiWatch do
  @moduledoc """
  Review one durable CI watch against current GitHub Actions state.
  """

  use Jido.Action,
    name: "jx_review_ci_watch",
    description: "Evaluate a durable CI watch and apply its terminal profile action",
    category: "jx",
    tags: ["ci", "github", "orchestration", "safe"],
    schema: [
      watch_id: [type: :string, required: true, doc: "CI watch id"],
      opts: [type: :keyword_list, default: [], doc: "Review options"]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{watch_id: watch_id, opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.review_ci_watch(watch_id, opts) end, :ci_watch)
  end
end
