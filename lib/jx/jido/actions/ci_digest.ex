defmodule JX.Jido.Actions.CiDigest do
  @moduledoc """
  Build a GitHub Actions PR check digest through the Workspace API.
  """

  use Jido.Action,
    name: "jx_ci_digest",
    description: "Summarize PR checks and classify failed GitHub Actions job logs",
    category: "jx",
    tags: ["ci", "github", "checks", "safe"],
    schema: [
      repo: [type: :string, required: true, doc: "GitHub repository as owner/repo"],
      pr: [type: :integer, required: true, doc: "Pull request number"],
      opts: [type: :keyword_list, default: [], doc: "Digest options"]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{repo: repo, pr: pr, opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.ci_digest(repo, pr, opts) end, :ci_digest)
  end
end
