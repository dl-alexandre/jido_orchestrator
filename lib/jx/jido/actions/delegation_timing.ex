defmodule JX.Jido.Actions.DelegationTiming do
  @moduledoc """
  Summarize delegation runtime history, active elapsed time, and pending review age.
  """

  use Jido.Action,
    name: "jx_delegation_timing",
    description:
      "Summarize how long delegated tasks take and which active or review items are aging",
    category: "jx",
    tags: ["delegation", "timing", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    WorkspaceAction.call(fn -> {:ok, Workspace.delegation_timing(opts)} end, :timing)
  end
end
