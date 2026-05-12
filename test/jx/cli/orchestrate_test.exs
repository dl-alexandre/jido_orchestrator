defmodule JX.CLI.OrchestrateTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Orchestrate

  defmodule FakeWorkspace do
    def orchestrate(opts) do
      send(self(), {:orchestrate, opts})
      {:ok, report(opts)}
    end

    defp report(opts) do
      %{
        generated_at: "2026-05-12T00:00:00Z",
        consumer: opts[:consumer] || "orchestrator",
        mode: if(opts[:execute], do: "execute", else: "dry-run"),
        scan: scan(),
        inbox: %{
          cursor: %{consumer: "orchestrator", source: "test", last_event_id: 3},
          latest_event_id: 4,
          unread_total: 1,
          matching_unread_total: 1,
          returned: 1,
          events: [event()]
        },
        decisions: [
          %{
            id: "rec-1",
            status: "planned",
            safety: "safe",
            action: "prompt",
            ref: "ref-1",
            state: "active",
            prompt_status: "ready",
            event_ids: [4],
            reason: "ready to continue",
            message: "continue"
          }
        ],
        action_queue: nil,
        execution: %{mode: "dry-run"},
        heartbeat: nil,
        cursor: nil,
        errors: []
      }
    end

    defp scan do
      %{
        generated_at: "2026-05-12T00:00:00Z",
        observed: true,
        observation_refresh: %{saved: 1},
        sessions_total: 1,
        events_saved: 1,
        events: [event()],
        queues_total: 0,
        queues: [],
        watches_total: 0,
        watch_updates: [],
        watch_actions_total: 0,
        watch_actions: [],
        ci_watches_total: 0,
        ci_watch_updates: [],
        wake_triggers_total: 0,
        wake_notifications_saved: 0,
        wake_triggers: [],
        call_handoffs_total: 0,
        call_handoffs: [],
        delegations_total: 0,
        delegations: [],
        delegation_reviews_total: 0,
        delegation_reviews: [],
        delegation_preflight: %{},
        delegation_timing: %{active: %{long_running: 0}},
        notifications_saved: 0,
        notifications: [],
        profiles_total: 1,
        profiles: [],
        errors: []
      }
    end

    defp event do
      %{
        id: 4,
        event_id: "evt-4",
        kind: "session.changed",
        severity: "notice",
        ref: "ref-1",
        project: "saysure",
        session_type: "agent",
        session_kind: "codex",
        control_mode: "managed",
        work_state: "running",
        action: "observe",
        summary: "session changed",
        fingerprint: "fingerprint",
        payload: "{}",
        inserted_at: "2026-05-12T00:00:00Z"
      }
    end
  end

  test "step parses orchestration options and renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   [
                     "step",
                     "--consumer",
                     "operator",
                     "--host",
                     "local",
                     "--type",
                     "agent",
                     "--work-state",
                     "running",
                     "--control",
                     "managed",
                     "--prompt-status",
                     "ready",
                     "--no-observe",
                     "--lines",
                     "12",
                     "--scan-limit",
                     "9",
                     "--queue-limit",
                     "4",
                     "--event-limit",
                     "3",
                     "--decision-limit",
                     "2",
                     "--min-observe-age-seconds",
                     "0",
                     "--execute",
                     "--ack",
                     "--auto-plan",
                     "--no-enter",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:orchestrate, opts}
    assert opts[:consumer] == "operator"
    assert opts[:host_name] == "local"
    assert opts[:type] == "agent"
    assert opts[:work_state] == "running"
    assert opts[:control_mode] == "managed"
    assert opts[:prompt_status] == "ready"
    assert opts[:observe] == false
    assert opts[:lines] == 12
    assert opts[:limit] == 9
    assert opts[:queue_limit] == 4
    assert opts[:event_limit] == 3
    assert opts[:decision_limit] == 2
    assert opts[:min_observe_age_seconds] == 0
    assert opts[:execute] == true
    assert opts[:ack] == true
    assert opts[:auto_plan] == true
    assert opts[:enter] == false

    assert %{"consumer" => "operator", "scan" => %{"sessions_total" => 1}} =
             Jason.decode!(output)
  end

  test "run honors bounded iterations" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(["run", "--iterations", "2", "--interval-ms", "1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:orchestrate, _opts}
    assert_received {:orchestrate, _opts}
    assert output =~ "orchestrate iteration 1"
    assert output =~ "orchestrate iteration 2"
    assert output =~ "decisions"
    assert output =~ "execution: dry-run"
  end

  test "invalid numeric options are rejected before starting the app" do
    assert {:error, message} =
             Orchestrate.run(["step", "--interval-ms", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "interval-ms must be a positive integer"
    refute_received :started
    refute_received :orchestrate
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
