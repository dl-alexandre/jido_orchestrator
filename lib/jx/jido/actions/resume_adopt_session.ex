defmodule JX.Jido.Actions.ResumeAdoptSession do
  @moduledoc """
  Plan or execute resume-aware adoption of a Zed/ACP-launched agent.
  """

  use Jido.Action,
    name: "jx_resume_adopt_session",
    description: "Plan resume adoption or relaunch a Zed/ACP agent under managed tmux",
    category: "jx",
    tags: ["sessions", "adoption", "manual", "zed", "acp"],
    schema: [
      ref: [type: :string, required: true, doc: "Stable session ref"],
      project: [type: :string, required: true, doc: "Project to own the managed replacement"],
      agent_name: [
        type: :string,
        default: "",
        doc: "Agent binary to relaunch; defaults to the discovered session kind"
      ],
      relaunch: [
        type: :boolean,
        default: false,
        doc: "When true, start a managed tmux replacement with resume context"
      ]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{ref: ref, project: project, agent_name: agent_name, relaunch: relaunch}, _context) do
    opts =
      []
      |> maybe_put(:agent_name, agent_name)
      |> Keyword.put(:relaunch, relaunch)

    WorkspaceAction.call(fn -> Workspace.resume_adopt_session(ref, project, opts) end, :adoption)
  end

  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
