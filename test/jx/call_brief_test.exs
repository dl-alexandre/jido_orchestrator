defmodule JX.CallBriefTest do
  use ExUnit.Case, async: true

  alias JX.CallBrief

  test "builds a prioritized call brief from notifications, inbox, and watches" do
    now = DateTime.utc_now()

    brief =
      CallBrief.build(
        %{
          operator: %{
            key: "default",
            source: "stored",
            preferences: "Prefer autonomous watches over foreground polling.",
            working_style: "Keep compact handoffs.",
            escalation_policy: "Ask before destructive actions."
          },
          portfolio: %{
            observed: false,
            projects_total: 1,
            totals: %{
              sessions_total: 2,
              ready_sessions: 1,
              blocked_sessions: 1,
              awaiting_observation: 0,
              running_sessions: 1
            },
            projects: [
              %{
                name: "saysure",
                host: "local",
                sessions_total: 2,
                blocked_total: 1,
                ready_total: 1,
                awaiting_total: 0,
                running_total: 1,
                next_action: "resolve blocked session before prompting",
                focus: "agent workspace orchestration",
                refs: [%{ref: "s-one"}, %{ref: "s-two"}]
              }
            ]
          },
          inbox: %{
            observed: false,
            sections: %{
              needs_judgment: [
                %{
                  ref: "s-one",
                  project: "saysure",
                  state: "blocked",
                  prompt_status: "blocked",
                  work_state: "waiting",
                  next_step: "decide whether to retry the failing task"
                }
              ],
              ready: [
                %{
                  ref: "s-two",
                  project: "saysure",
                  state: "ready-to-send",
                  prompt_status: "ready",
                  work_state: "idle",
                  next_step: "send the chambered follow-up"
                }
              ],
              awaiting_observation: []
            }
          },
          heartbeats: [
            %{
              status: "running",
              consumer: "orchestrator",
              mode: "dry-run",
              last_scan_at: now,
              next_wake_at: now,
              scan_snapshot:
                Jason.encode!(%{
                  guidance: %{
                    top_priority: "review blocked session",
                    autonomous_next: "keep watching CI and session changes",
                    operator_needed_for: ["blocked session strategy"],
                    focus_refs: ["s-one"]
                  }
                })
            }
          ],
          notifications: [
            %{
              notification_id: "ntf-one",
              severity: "warning",
              status: "unread",
              kind: "session.blocked",
              ref: "s-one",
              project: "saysure",
              summary: "blocked session needs strategy",
              updated_at: now
            }
          ],
          ci_watches: [
            %{
              watch_id: "ciw-one",
              status: "active",
              mode: "notify",
              repo: "org/repo",
              pr_number: 461,
              ref: "s-two",
              project: "saysure",
              last_summary: "PR #461 checks pending",
              updated_at: now
            }
          ],
          handoffs: [
            %{
              handoff_id: "cal-one",
              surface: "call",
              status: "open",
              project: "saysure",
              ref: "s-one",
              title: "Operator wants this tracked",
              summary: "Review blocked strategy before next push",
              updated_at: now
            }
          ],
          delegations: [
            %{
              delegation_id: "dlg-one",
              status: "running",
              priority: 3,
              project: "saysure",
              ref: "s-two",
              owner: "worker-1",
              agent_kind: "worker",
              title: "Patch failing CI",
              brief: "Inspect failing test logs and patch the smallest relevant code path.",
              updated_at: now
            }
          ]
        },
        limit: 6
      )

    assert brief.surface == "call"
    assert brief.mode == "brief"
    assert brief.headline == "Operator attention needed: warning session.blocked"
    assert brief.context.projects_total == 1
    assert brief.context.warning_notifications == 1
    assert brief.context.open_handoffs == 1
    assert brief.context.open_delegations == 1
    assert brief.orchestrator.top_priority == "review blocked session"

    assert [%{kind: "notification"}, %{kind: "judgment"} | _rest] = brief.agenda
    assert Enum.any?(brief.agenda, &(&1.kind == "handoff"))
    assert Enum.any?(brief.agenda, &(&1.kind == "delegation"))
    assert Enum.any?(brief.agenda, &(&1.kind == "ci_watch"))

    assert [%{name: "saysure", refs: ["s-one", "s-two"]}] = brief.projects
    assert [%{id: "cal-one"}] = brief.handoffs
    assert [%{id: "dlg-one"}] = brief.delegations
    assert is_binary(Jason.encode!(brief))
  end

  test "returns an idle brief when no agenda items are present" do
    brief =
      CallBrief.build(%{
        portfolio: %{totals: %{}, projects: [], projects_total: 0},
        inbox: %{sections: %{}},
        notifications: [],
        ci_watches: [],
        heartbeats: []
      })

    assert brief.headline == "No urgent operator action."

    assert brief.agenda == []
    assert brief.orchestrator.status == "unknown"
    assert brief.next =~ "Keep background orchestration running"
  end

  test "failed CI watches lead the agenda without duplicate PR entries" do
    brief =
      CallBrief.build(%{
        portfolio: %{totals: %{}, projects: [], projects_total: 0},
        inbox: %{sections: %{}},
        notifications: [
          %{
            notification_id: "ntf-warning",
            severity: "warning",
            status: "unread",
            kind: "session.blocked",
            summary: "older blocked notification"
          }
        ],
        ci_watches: [
          %{
            watch_id: "ciw-new",
            status: "failed",
            mode: "prompt",
            repo: "org/repo",
            pr_number: 461,
            ref: "s-ci",
            last_summary: "PR #461 checks failed: Test"
          },
          %{
            watch_id: "ciw-old",
            status: "failed",
            mode: "prompt",
            repo: "org/repo",
            pr_number: 461,
            ref: "s-ci",
            last_summary: "PR #461 checks failed: old run"
          }
        ],
        heartbeats: []
      })

    assert brief.headline == "CI watch needs review: PR #461 checks failed: Test"
    assert [%{kind: "ci_watch", id: "ciw-new"}, %{kind: "notification"}] = brief.agenda
  end

  test "delegation preflight warnings are promoted in the call agenda" do
    brief =
      CallBrief.build(%{
        portfolio: %{totals: %{}, projects: [], projects_total: 0},
        inbox: %{sections: %{}},
        notifications: [],
        ci_watches: [],
        delegations: [
          %{
            delegation_id: "dlg-conflict",
            status: "queued",
            priority: 0,
            project: "saysure",
            ref: "s-conflict",
            agent_kind: "worker",
            title: "Scale cleanup",
            brief: "Refactor scale helper.",
            lint_warnings: Jason.encode!(["write path lib/one overlaps lib/one/scale.ex"]),
            write_paths: Jason.encode!(["lib/one"]),
            evidence:
              Jason.encode!([
                %{
                  command: "mix test",
                  cwd: "/repo",
                  exit_status: 0,
                  status: "passed"
                }
              ]),
            residual_risks: Jason.encode!(["full suite not rerun"]),
            review: %{decision: "hold", summary: "hold: residual risks need foreground review"}
          }
        ],
        heartbeats: []
      })

    assert brief.headline ==
             "Delegation needs review: write path lib/one overlaps lib/one/scale.ex"

    assert [%{kind: "delegation", detail: detail, label: label}] = brief.agenda
    assert detail =~ "preflight-warning"
    assert label == "write path lib/one overlaps lib/one/scale.ex"

    assert [
             %{
               id: "dlg-conflict",
               lint_warnings: [_],
               write_paths: ["lib/one"],
               evidence_count: 1,
               latest_evidence: %{"command" => "mix test"},
               residual_risks: ["full suite not rerun"],
               review: %{decision: "hold"}
             }
           ] =
             brief.delegations
  end

  test "pending delegation reviews are promoted ahead of active delegation queue" do
    brief =
      CallBrief.build(%{
        portfolio: %{totals: %{}, projects: [], projects_total: 0},
        inbox: %{sections: %{}},
        notifications: [],
        ci_watches: [],
        delegation_reviews: [
          %{
            delegation_id: "dlg-review",
            status: "completed",
            decision: "revise",
            project: "saysure",
            ref: "s-review",
            title: "Worker patch",
            summary: "needs revision: artifacts include paths outside declared write ownership",
            warnings: ["artifacts include paths outside declared write ownership"],
            evidence: %{passed: 1, failed: 0},
            ownership: %{outside_write_paths: ["test/example_test.exs"]},
            foreground: %{status: "pending"}
          }
        ],
        delegations: [
          %{
            delegation_id: "dlg-running",
            status: "running",
            priority: 0,
            project: "saysure",
            ref: "s-running",
            agent_kind: "worker",
            title: "Running work"
          }
        ],
        heartbeats: []
      })

    assert brief.headline =~ "Delegation integration needed"
    assert [%{kind: "delegation_review", id: "dlg-review"} | _rest] = brief.agenda
    assert brief.context.pending_delegation_reviews == 1
    assert [%{id: "dlg-review", decision: "revise", warnings: [_]}] = brief.delegation_reviews
    assert brief.next =~ "Decide delegation review dlg-review"
  end
end
