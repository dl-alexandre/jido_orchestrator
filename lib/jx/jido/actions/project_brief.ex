defmodule JX.Jido.Actions.ProjectBrief do
  @moduledoc """
  Return a project-scoped orchestration brief.
  """

  use Jido.Action,
    name: "jx_project_brief",
    description: "Build a project gateway brief with next mode guidance",
    category: "jx",
    tags: ["project", "brief", "orchestration", "safe"],
    schema: [
      project: [type: :string, required: true, doc: "Project name"],
      opts: [type: :keyword_list, default: [], doc: "Workspace project brief options"]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{project: project, opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.project_brief(project, opts) end, :project_brief)
  end
end
