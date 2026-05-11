defmodule JX.Jido.Actions.DoctorHost do
  @moduledoc """
  Run host preflight checks through the Workspace API.
  """

  use Jido.Action,
    name: "jx_doctor_host",
    description: "Run host doctor checks for execution, workspace, Git, tmux, and agents",
    category: "jx",
    tags: ["host", "doctor", "safe"],
    schema: [
      host_name: [type: :string, required: true, doc: "Registered host name"],
      opts: [type: :keyword_list, default: [], doc: "Doctor options"]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{host_name: host_name, opts: opts}, _context) do
    WorkspaceAction.call(fn -> Workspace.doctor_host(host_name, opts) end, :doctor_report)
  end
end
