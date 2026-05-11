defmodule JX.Jido.Actions.CaptureSession do
  @moduledoc """
  Capture visible output from one tmux-backed session.
  """

  use Jido.Action,
    name: "jx_capture_session",
    description: "Capture a tmux-backed session by stable ref",
    category: "jx",
    tags: ["sessions", "capture", "safe"],
    schema: [
      ref: [type: :string, required: true, doc: "Stable session ref"],
      opts: [type: :keyword_list, default: [], doc: "Capture options"]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{ref: ref, opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.capture_session(ref, opts) end, :capture)
  end
end
