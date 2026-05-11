defmodule JX.Approvals.Recommendation do
  @moduledoc """
  Text-only next safe actions for approval review items.
  """

  alias JX.Approvals.Approval

  @spec build(Approval.t(), map()) :: map()
  def build(%Approval{} = approval, evidence) do
    actions =
      approval
      |> actions_for(evidence)
      |> Kernel.++(["Dismiss if expected."])
      |> Enum.uniq()

    %{
      primary: List.first(actions) || "Run `jx devide status #{approval.workspace_id}`.",
      actions: actions
    }
  end

  defp actions_for(%Approval{kind: "proposal_conflict"} = approval, _evidence) do
    [
      "Open DevIDE workspace and inspect proposal.",
      "Run `jx devide status #{approval.workspace_id}`."
    ]
  end

  defp actions_for(%Approval{kind: "unsafe_db"} = approval, _evidence) do
    [
      "Open DevIDE workspace and inspect database isolation.",
      "Run `jx devide status #{approval.workspace_id}`."
    ]
  end

  defp actions_for(%Approval{kind: "failed_run"} = approval, _evidence) do
    [
      "Run `jx devide status #{approval.workspace_id}`.",
      "Re-run tests in DevIDE."
    ]
  end

  defp actions_for(%Approval{kind: "policy_blocked"} = approval, _evidence) do
    [
      "Open DevIDE workspace and inspect policy audit.",
      "Run `jx devide status #{approval.workspace_id}`."
    ]
  end

  defp actions_for(%Approval{} = approval, _evidence) do
    ["Run `jx devide status #{approval.workspace_id}`."]
  end
end
