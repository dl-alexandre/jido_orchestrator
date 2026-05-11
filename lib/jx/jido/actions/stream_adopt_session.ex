defmodule JX.Jido.Actions.StreamAdoptSession do
  @moduledoc """
  Plan or execute adoption of a process-only agent into managed Jido transport.
  """

  use Jido.Action,
    name: "jx_stream_adopt_session",
    description: "Plan stream adoption or relaunch a process-only agent under managed tmux",
    category: "jx",
    tags: ["sessions", "adoption", "manual"],
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
        doc: "When true, start a managed tmux replacement task"
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

    WorkspaceAction.call(fn -> Workspace.stream_adopt_session(ref, project, opts) end, :adoption)
  end

  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
