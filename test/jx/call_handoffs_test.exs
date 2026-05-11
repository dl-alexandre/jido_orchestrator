defmodule JX.CallHandoffsTest do
  use ExUnit.Case, async: false

  alias JX.CallHandoffs
  alias JX.CallHandoffs.CallHandoff
  alias JX.Repo

  setup do
    Repo.delete_all(CallHandoff)
    :ok
  end

  test "creates lists and closes call handoffs" do
    assert {:ok, %CallHandoff{} = handoff} =
             CallHandoffs.create(
               %{
                 surface: "meet",
                 project: "saysure",
                 ref: "s-one",
                 title: "Morning orchestration",
                 summary: "Operator approved continuing background CI review.",
                 operator_input: "Keep me out of the loop unless CI fails.",
                 decisions: ["continue asynchronously"],
                 follow_ups: ["summarize blockers on next call"]
               },
               brief_snapshot: %{headline: "No urgent operator action."}
             )

    assert handoff.handoff_id =~ "cal-"
    assert handoff.status == "open"
    assert Jason.decode!(handoff.decisions) == ["continue asynchronously"]
    assert Jason.decode!(handoff.brief_snapshot)["headline"] == "No urgent operator action."

    assert [listed] = CallHandoffs.list(status: "open", project: "saysure")
    assert listed.handoff_id == handoff.handoff_id

    assert %{open_total: 1, latest: [%{handoff_id: handoff_id}]} = CallHandoffs.summary()
    assert handoff_id == handoff.handoff_id

    assert {:ok, closed} = CallHandoffs.close(handoff.handoff_id, "handled in daemon")
    assert closed.status == "closed"
    assert closed.summary =~ "handled in daemon"
    assert %DateTime{} = closed.closed_at
  end
end
