defmodule JX.Jido.Actions.ProbeRemoteSessions do
  @moduledoc """
  Probe remote tmux sessions behind SSH shell panes.
  """

  use Jido.Action,
    name: "jx_probe_remote_sessions",
    description: "Probe remote tmux inventory for eligible SSH panes",
    category: "jx",
    tags: ["remote", "probe", "gated"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.probe_remote_sessions(opts) end, :probe_report)
  end
end
