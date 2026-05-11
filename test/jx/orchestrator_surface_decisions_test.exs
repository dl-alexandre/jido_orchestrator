defmodule JX.OrchestratorSurfaceDecisionsTest do
  use ExUnit.Case, async: true

  alias JX.OrchestratorSurfaceDecisions

  test "build promotes handoffs delegation reviews and CI transitions into decisions" do
    scan = %{
      call_handoffs: [
        %{handoff_id: "cal-one", ref: "s-call", title: "Operator asked for follow-up"}
      ],
      delegation_reviews: [
        %{delegation_id: "dlg-one", ref: "s-delegate", worker_summary: "Patch ready"}
      ],
      ci_watch_updates: [
        %{
          changed?: true,
          status: "failed",
          summary: "PR #42 checks failed",
          watch: %{watch_id: "ciw-one", ref: "s-ci", repo: "org/repo", pr_number: 42}
        },
        %{
          changed?: false,
          status: "active",
          watch: %{watch_id: "ciw-two", ref: "s-ci"}
        }
      ]
    }

    events = [
      %{id: 1, ref: "s-call"},
      %{id: 2, ref: "s-delegate"},
      %{id: 3, ref: "s-ci"}
    ]

    assert [
             %{action: "review-call-handoff", safety: "manual", event_ids: [1]},
             %{action: "decide-delegation-review", safety: "manual", event_ids: [2]},
             %{action: "review-ci-watch", safety: "inspect", event_ids: [3]}
           ] = OrchestratorSurfaceDecisions.build(scan, events)
  end
end
