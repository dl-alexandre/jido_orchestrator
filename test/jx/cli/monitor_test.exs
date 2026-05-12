defmodule JX.CLI.MonitorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Monitor

  defmodule FakeWorkspace do
    def monitor_scan(opts) do
      send(self(), {:monitor_scan, opts})
      {:ok, scan()}
    end

    def monitor_event_status(opts) do
      send(self(), {:monitor_event_status, opts})

      %{
        consumer: opts[:consumer] || "default",
        cursor: %{
          consumer: opts[:consumer] || "default",
          source: "test",
          last_event_id: 3,
          last_seen_at: "2026-05-12T00:00:00Z",
          updated_at: "2026-05-12T00:00:01Z"
        },
        latest_event_id: 4,
        unread_total: 1,
        caught_up: false,
        latest_event: event()
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
        queues_total: 1,
        queues: [
          %{
            action: "prompt",
            total: 1,
            by_priority: %{"high" => 1},
            by_safety: %{"safe" => 1},
            by_control: %{"managed" => 1},
            items: [%{ref: "ref-1", task: "continue", current_path: "/tmp/work", pane: "p1"}]
          }
        ],
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

  test "scan parses filters and renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(
                   [
                     "scan",
                     "--host",
                     "local",
                     "--type",
                     "agent",
                     "--work-state",
                     "running",
                     "--no-observe",
                     "--lines",
                     "12",
                     "--scan-limit",
                     "9",
                     "--queue-limit",
                     "4",
                     "--event-limit",
                     "3",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:monitor_scan, opts}
    assert opts[:host_name] == "local"
    assert opts[:type] == "agent"
    assert opts[:work_state] == "running"
    assert opts[:observe] == false
    assert opts[:lines] == 12
    assert opts[:limit] == 9
    assert opts[:queue_limit] == 4
    assert opts[:event_limit] == 3

    assert %{"sessions_total" => 1, "events" => [%{"event_id" => "evt-4"}]} =
             Jason.decode!(output)
  end

  test "run honors bounded iterations" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["run", "--iterations", "2", "--interval-ms", "1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:monitor_scan, _opts}
    assert_received {:monitor_scan, _opts}
    assert output =~ "monitor iteration 1"
    assert output =~ "monitor iteration 2"
  end

  test "status routes through monitor event status" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["status", "--consumer", "operator", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:monitor_event_status, [consumer: "operator"]}

    assert %{"consumer" => "operator", "latest_event" => %{"event_id" => "evt-4"}} =
             Jason.decode!(output)
  end

  test "invalid numeric options are rejected before starting the app" do
    assert {:error, message} =
             Monitor.run(["scan", "--event-limit", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "event-limit must be a positive integer"
    refute_received :started
    refute_received :monitor_scan
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
