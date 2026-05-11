defmodule JX.OrchestrationActionsTest do
  use ExUnit.Case, async: false

  alias JX.OrchestrationActions
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Repo

  setup do
    Repo.delete_all(OrchestrationAction)
    :ok
  end

  test "summary latest entries are json encodable snapshots" do
    assert %{saved: 1, records: [_action], errors: []} =
             OrchestrationActions.record_planned("requested", [
               %{
                 id: "rec-one",
                 action: "observe",
                 safety: "safe",
                 ref: "s-one",
                 target: "default/session:0.0",
                 reason: "fresh capture needed"
               }
             ])

    assert %{
             latest: [
               %{
                 action: "observe",
                 safety: "safe",
                 ref: "s-one",
                 status: "planned",
                 outcome: ""
               }
             ]
           } = summary = OrchestrationActions.summary()

    assert is_binary(Jason.encode!(summary))
  end

  test "executed planner action records helpful outcome on the existing queue entry" do
    decision = %{
      id: "rec-plan",
      action: "auto-plan-next",
      safety: "safe",
      ref: "s-one",
      reason: "completed session needs a follow-up"
    }

    assert %{saved: 1, records: [%OrchestrationAction{outcome: ""}]} =
             OrchestrationActions.record_planned("orchestrate", [decision])

    assert %{saved: 1, records: [record]} =
             OrchestrationActions.record_results("orchestrate", [
               Map.merge(decision, %{
                 status: "executed",
                 result_summary: "next prompt auto-planned"
               })
             ])

    assert record.status == "executed"
    assert record.outcome == "helpful"
    assert record.outcome_reason == "next prompt auto-planned"
    assert %DateTime{} = record.completed_at

    assert %{by_outcome: %{"helpful" => 1}} = OrchestrationActions.summary()
  end

  test "skipped gated action records blocked outcome without LLM judgment" do
    assert %{saved: 1, records: [record]} =
             OrchestrationActions.record_results("orchestrate", [
               %{
                 id: "rec-send",
                 action: "send-profile-prompt",
                 safety: "gated",
                 status: "skipped",
                 ref: "s-one",
                 reason: "send-profile-prompt requires --yes"
               }
             ])

    assert record.outcome == "blocked"
    assert record.outcome_reason == "send-profile-prompt requires --yes"
    assert %DateTime{} = record.completed_at
  end

  test "explicit action outcome wins over deterministic fallback" do
    assert %{saved: 1, records: [record]} =
             OrchestrationActions.record_results("orchestrate", [
               %{
                 id: "rec-old",
                 action: "observe",
                 safety: "safe",
                 status: "skipped",
                 outcome: "superseded",
                 outcome_reason: "newer observation already exists",
                 ref: "s-one",
                 reason: "skipped by policy"
               }
             ])

    assert record.outcome == "superseded"
    assert record.outcome_reason == "newer observation already exists"
  end
end
