defmodule JX.Jido.Actions.SendSession do
  @moduledoc """
  Send a directive to one managed or task-owned session.
  """

  use Jido.Action,
    name: "jx_send_session",
    description: "Send text to a session after Workspace directive policy authorizes it",
    category: "jx",
    tags: ["sessions", "send", "gated"],
    schema: [
      ref: [type: :string, required: true, doc: "Stable session ref"],
      message: [type: :string, required: true, doc: "Message to send"],
      opts: [type: :keyword_list, default: [], doc: "Send options"]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{ref: ref, message: message, opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.send_session(ref, message, opts) end, :directive)
  end
end
