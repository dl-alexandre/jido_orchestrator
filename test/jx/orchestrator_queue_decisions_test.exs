defmodule JX.OrchestratorQueueDecisionsTest do
  use ExUnit.Case, async: true

  alias JX.OrchestratorQueueDecisions

  test "build promotes observe queue items into inspect decisions" do
    queues = [
      %{
        action: "observe",
        total: 1,
        items: [
          %{
            ref: "build-1:agent:main",
            reason: "a sent directive needs a fresh observation"
          }
        ]
      }
    ]

    profiles = [
      %{
        ref: "build-1:agent:main",
        session: %{control_mode: "managed"},
        comparison: %{state: "tracking"},
        next_prompt: %{status: "sent", text: "Report status."},
        actual: %{
          last_directive: %{
            sent_at: "2026-04-26T18:00:00Z",
            message: "Fallback directive"
          }
        }
      }
    ]

    events = [
      %{id: 41, ref: "build-1:agent:main"},
      %{id: 42, ref: "other-session"}
    ]

    assert [
             %{
               action: "observe",
               source: "queue",
               queue_action: "observe",
               safety: "inspect",
               status: "planned",
               ref: "build-1:agent:main",
               state: "tracking",
               prompt_status: "sent",
               directive_sent_at: "2026-04-26T18:00:00Z",
               directive_message: "Report status.",
               reason: "a sent directive needs a fresh observation",
               event_ids: [41]
             } = decision
           ] = OrchestratorQueueDecisions.build(queues, profiles, events)

    assert String.starts_with?(decision.id, "orc-")
  end

  test "build suppresses ignored and protected sessions" do
    queues = [
      %{
        action: "observe",
        total: 2,
        items: [%{ref: "ignored-ref"}, %{ref: "protected-ref"}]
      }
    ]

    profiles = [
      %{ref: "ignored-ref", session: %{control_mode: "ignored"}},
      %{ref: "protected-ref", session: %{control_mode: "protected"}}
    ]

    assert [] = OrchestratorQueueDecisions.build(queues, profiles, [])
  end

  test "build respects include_current option" do
    queues = [%{action: "observe", total: 1, items: [%{ref: "ref-1"}]}]
    profiles = [%{ref: "ref-1", session: %{control_mode: "managed"}}]

    assert [] = OrchestratorQueueDecisions.build(queues, profiles, [], include_current: false)
  end
end
