defmodule JX.OrchestratorGuidanceTest do
  use ExUnit.Case, async: true

  alias JX.OrchestratorGuidance

  test "guidance uses queue buckets when profile states are compact or stale" do
    report = %{
      mode: "execute+ack",
      errors: [],
      decisions: [],
      inbox: %{unread_total: 3},
      execution: %{executed: [], skipped: []},
      scan: %{
        profiles: [],
        notifications: [],
        watch_actions_total: 0,
        queues: [
          %{
            action: "blocked-profile",
            total: 2,
            items: [%{ref: "s-blocked-1"}, %{ref: "s-blocked-2"}]
          },
          %{action: "send-session", total: 1, items: [%{ref: "s-directable"}]},
          %{action: "observe", total: 1, items: [%{ref: "s-awaiting"}]}
        ]
      }
    }

    guidance = OrchestratorGuidance.build(report)

    assert guidance.counts.blocked == 2
    assert guidance.counts.awaiting == 1
    assert guidance.counts.ready == 0
    assert guidance.counts.directable == 1
    assert guidance.top_priority =~ "observe queue"
    assert "blocked session strategy" in guidance.operator_needed_for
    assert guidance.focus_refs == ["s-blocked-1", "s-blocked-2", "s-directable", "s-awaiting"]
  end

  test "guidance prioritizes ready managed prompts over blocked backlog" do
    report = %{
      mode: "execute+ack",
      errors: [],
      decisions: [],
      inbox: %{unread_total: 0},
      execution: %{executed: [], skipped: []},
      scan: %{
        queues: [
          %{action: "blocked-profile", total: 8, items: [%{ref: "s-blocked"}]}
        ],
        notifications: [],
        watch_actions_total: 0,
        profiles: [
          %{
            ref: "s-ready",
            next_step: "send chambered prompt",
            comparison: %{state: "ready-to-send"},
            next_prompt: %{status: "ready"},
            planned: %{}
          }
        ]
      }
    }

    guidance = OrchestratorGuidance.build(report)

    assert guidance.top_priority == "ready s-ready: send chambered prompt"
    assert "blocked session strategy" in guidance.operator_needed_for
  end

  test "guidance surfaces open call handoffs as operator work" do
    report = %{
      mode: "execute+ack",
      errors: [],
      decisions: [],
      inbox: %{unread_total: 1},
      execution: %{executed: [], skipped: []},
      scan: %{
        queues: [],
        notifications: [],
        watch_actions_total: 0,
        call_handoffs_total: 2,
        profiles: []
      }
    }

    guidance = OrchestratorGuidance.build(report)

    assert guidance.counts.handoffs == 2
    assert guidance.top_priority == "call handoff queue: 2 open handoff(s)"

    assert guidance.autonomous_next ==
             "review open call handoffs and convert them into prompts, watches, or closures"

    assert "call handoff" in guidance.operator_needed_for
  end

  test "guidance surfaces active delegations as integration work" do
    report = %{
      mode: "execute+ack",
      errors: [],
      decisions: [],
      inbox: %{unread_total: 1},
      execution: %{executed: [], skipped: []},
      scan: %{
        queues: [],
        notifications: [],
        watch_actions_total: 0,
        call_handoffs_total: 0,
        delegations_total: 2,
        profiles: []
      }
    }

    guidance = OrchestratorGuidance.build(report)

    assert guidance.counts.delegations == 2
    assert guidance.top_priority == "delegation queue: 2 active packet(s)"

    assert guidance.autonomous_next ==
             "review active delegation packets and integrate worker results"

    assert "delegation review" in guidance.operator_needed_for
  end

  test "guidance surfaces completed delegation reviews before active delegation backlog" do
    report = %{
      mode: "execute+ack",
      errors: [],
      decisions: [],
      inbox: %{unread_total: 1},
      execution: %{executed: [], skipped: []},
      scan: %{
        queues: [],
        notifications: [],
        watch_actions_total: 0,
        call_handoffs_total: 0,
        delegations_total: 2,
        delegation_reviews_total: 1,
        delegation_reviews: [%{delegation_id: "dlg-one", ref: "s-review"}],
        delegation_timing: %{
          active: %{long_running: 0},
          pending_reviews: %{stale: 0}
        },
        profiles: []
      }
    }

    guidance = OrchestratorGuidance.build(report)

    assert guidance.counts.delegation_reviews == 1
    assert guidance.top_priority == "delegation review queue: 1 completed packet(s)"

    assert guidance.autonomous_next ==
             "review completed delegation output and record accept/revise/reject/hold decisions"

    assert "delegation integration decision" in guidance.operator_needed_for
    assert "s-review" in guidance.focus_refs
  end

  test "guidance surfaces long-running delegations as timing work" do
    report = %{
      mode: "execute+ack",
      errors: [],
      decisions: [],
      inbox: %{unread_total: 1},
      execution: %{executed: [], skipped: []},
      scan: %{
        queues: [],
        notifications: [],
        watch_actions_total: 0,
        call_handoffs_total: 0,
        delegations_total: 2,
        delegation_reviews_total: 0,
        delegation_timing: %{
          active: %{long_running: 1},
          pending_reviews: %{stale: 0}
        },
        profiles: []
      }
    }

    guidance = OrchestratorGuidance.build(report)

    assert guidance.counts.delegation_long_running == 1
    assert guidance.top_priority == "delegation runtime watch: 1 long-running packet(s)"

    assert guidance.autonomous_next ==
             "inspect long-running delegations before assigning more overlapping work"

    assert "long-running delegation" in guidance.operator_needed_for
  end

  test "guidance counts stale sessions from profile timing" do
    report = %{
      mode: "execute+ack",
      errors: [],
      decisions: [],
      inbox: %{unread_total: 0},
      execution: %{executed: [], skipped: []},
      scan: %{
        queues: [],
        notifications: [],
        watch_actions_total: 0,
        profiles: [
          %{
            ref: "s-stale",
            comparison: %{state: "tracking"},
            next_prompt: %{status: "none"},
            timing: %{stale: true}
          }
        ]
      }
    }

    guidance = OrchestratorGuidance.build(report)

    assert guidance.counts.stale == 1
    assert guidance.autonomous_next == "refresh stale session profiles"
  end

  test "guidance prioritizes delegation write conflicts before generic delegation review" do
    report = %{
      mode: "execute+ack",
      errors: [],
      decisions: [],
      inbox: %{unread_total: 1},
      execution: %{executed: [], skipped: []},
      scan: %{
        queues: [],
        notifications: [],
        watch_actions_total: 0,
        call_handoffs_total: 0,
        delegations_total: 2,
        delegation_preflight: %{
          total: 2,
          ready: 1,
          warning: 0,
          blocked: 1,
          warnings_total: 1,
          conflicts_total: 1
        },
        profiles: []
      }
    }

    guidance = OrchestratorGuidance.build(report)

    assert guidance.counts.delegation_conflicts == 1
    assert guidance.counts.delegation_blocked == 1
    assert guidance.top_priority == "delegation write conflict: 1 blocked packet(s)"

    assert guidance.autonomous_next ==
             "resolve delegation write conflicts before starting more worker agents"

    assert "delegation write conflict" in guidance.operator_needed_for
  end
end
