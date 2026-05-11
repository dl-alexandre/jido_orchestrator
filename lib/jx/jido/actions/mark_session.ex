defmodule JX.Jido.Actions.MarkSession do
  @moduledoc """
  Persist control policy for a discovered session.
  """

  use Jido.Action,
    name: "jx_mark_session",
    description: "Mark a session managed, ignored, or protected",
    category: "jx",
    tags: ["sessions", "control", "gated"],
    schema: [
      ref: [type: :string, required: true, doc: "Stable session ref"],
      mode: [
        type: {:in, ["managed", "ignored", "protected"]},
        required: true,
        doc: "Control mode"
      ],
      project: [type: :string, default: "", doc: "Optional owning project label"],
      note: [type: :string, default: "", doc: "Optional operator note"]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{ref: ref, mode: mode, project: project, note: note}, _context) do
    opts = control_opts(project, note)
    WorkspaceAction.call(fn -> Workspace.set_session_control(ref, mode, opts) end, :control)
  end

  defp control_opts(project, note) do
    []
    |> maybe_put(:project, project)
    |> maybe_put(:note, note)
  end

  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
