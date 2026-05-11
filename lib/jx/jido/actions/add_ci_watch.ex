defmodule JX.Jido.Actions.AddCiWatch do
  @moduledoc """
  Register a durable GitHub Actions PR watch.
  """

  use Jido.Action,
    name: "jx_add_ci_watch",
    description: "Create a durable CI watch for a pull request",
    category: "jx",
    tags: ["ci", "github", "orchestration", "gated"],
    schema: [
      repo: [type: :string, required: true, doc: "GitHub repository as owner/repo"],
      pr: [type: :integer, required: true, doc: "Pull request number"],
      ref: [type: :string, default: "", doc: "Optional session ref to update"],
      project: [type: :string, default: "", doc: "Optional project label"],
      head_sha: [type: :string, default: "", doc: "Optional PR head SHA to pin this watch"],
      mode: [type: {:in, ["notify", "hold", "prompt"]}, default: "notify", doc: "Watch mode"],
      goal: [type: :string, default: "", doc: "Watch goal"],
      success_prompt: [type: :string, default: "", doc: "Draft prompt when checks pass"],
      failure_prompt: [type: :string, default: "", doc: "Draft prompt when checks fail"]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(params, _context) do
    attrs = %{
      repo: params.repo,
      pr_number: params.pr,
      ref: params.ref,
      project: params.project,
      head_sha: params.head_sha,
      mode: params.mode,
      goal: params.goal,
      success_prompt: params.success_prompt,
      failure_prompt: params.failure_prompt
    }

    WorkspaceAction.call(fn -> Workspace.add_ci_watch(attrs) end, :ci_watch)
  end
end
