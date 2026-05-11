defmodule JX.NextStepTest do
  use ExUnit.Case, async: true

  alias JX.NextStep

  test "delegation review agenda maps to delegation mode" do
    next =
      NextStep.build(%{
        generated_at: "2026-04-28T12:00:00Z",
        next: "Decide delegation review dlg-123: evidence missing",
        agenda: [
          %{
            kind: "delegation_review",
            id: "dlg-123",
            label: "evidence missing"
          }
        ],
        orchestrator: %{status: "running", mode: "execute+ack", consumer: "orchestrator"}
      })

    assert next.mode == "delegation"
    assert next.mode_title == "Delegation Review"
    assert next.command == "jx delegate review dlg-123 --json"
    assert next.reason == "delegation_review: evidence missing"
  end

  test "ready session agenda maps to orchestrator review" do
    next =
      NextStep.build(%{
        next: "Send or revise the chambered prompt",
        agenda: [
          %{
            kind: "ready",
            ref: "s-123",
            label: "tests passed"
          }
        ],
        orchestrator: %{status: "running", mode: "execute+ack"}
      })

    assert next.mode == "session-control"
    assert next.command == "jx orchestrator review s-123"
  end

  test "empty agenda prefers daemon mode when orchestrator is running" do
    next =
      NextStep.build(%{
        next: "",
        agenda: [],
        orchestrator: %{
          status: "running",
          mode: "execute+ack",
          autonomous_next: "keep scanning sessions"
        }
      })

    assert next.mode == "daemon"
    assert next.command == "jx orchestrator status"
    assert next.next == "keep scanning sessions"
  end
end
