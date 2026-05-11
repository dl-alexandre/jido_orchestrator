defmodule JX.MonitorEventsTest do
  use ExUnit.Case, async: false

  alias JX.MonitorEvents
  alias JX.MonitorEvents.Event
  alias JX.Notifications
  alias JX.Notifications.Notification
  alias JX.OrchestratorHeartbeats
  alias JX.OrchestratorHeartbeats.Heartbeat
  alias JX.OrchestratorRuntime
  alias JX.Repo

  setup do
    Repo.delete_all(Notification)
    Repo.delete_all(Heartbeat)
    Repo.delete_all(Event)

    previous_dispatch = Application.get_env(:jx, :monitor_event_dispatch)

    on_exit(fn ->
      Application.put_env(:jx, :monitor_event_dispatch, previous_dispatch)
    end)

    :ok
  end

  test "record_scan persists events and emits Jido signals" do
    Application.put_env(:jx, :monitor_event_dispatch, {
      :pid,
      [
        target: self(),
        delivery_mode: :async,
        message_format: fn signal -> {:monitor_signal, signal} end
      ]
    })

    assert {:ok, [event]} =
             MonitorEvents.record_scan(%{
               queues: [
                 %{action: "mark-managed", total: 2}
               ]
             })

    assert event.kind == "queue.snapshot"
    assert_receive {:monitor_signal, %Jido.Signal{} = signal}
    assert signal.id == event.event_id
    assert signal.type == "queue.snapshot"
    assert signal.source == "/jx/monitor_events"
    assert signal.data.event_id == event.event_id
    assert signal.data.kind == "queue.snapshot"
    assert signal.data.payload["queues"] == [%{"action" => "mark-managed", "total" => 2}]
  end

  test "record_scan feeds monitor signals into the supervised orchestrator agent" do
    Application.put_env(:jx, :monitor_event_dispatch, {
      JX.Jido.SignalDispatch.Orchestrator,
      [delivery_mode: :sync]
    })

    assert {:ok, before_state} = OrchestratorRuntime.state()
    previous_total = before_state.agent.state.event_total

    assert {:ok, [event]} =
             MonitorEvents.record_scan(%{
               queues: [
                 %{action: "mark-managed", total: 3}
               ]
             })

    assert {:ok, after_state} = OrchestratorRuntime.state()

    assert after_state.agent.state.status == :event_seen
    assert after_state.agent.state.event_total == previous_total + 1
    assert after_state.agent.state.last_event_id == event.event_id
    assert after_state.agent.state.last_event_type == "queue.snapshot"
    assert after_state.agent.state.last_event_summary == event.summary
  end

  test "to_signal preserves operational event metadata" do
    event =
      %Event{}
      |> Event.changeset(%{
        event_id: "evt-test",
        kind: "session.blocked",
        severity: "warning",
        ref: "session-1",
        project: "saysure",
        session_type: "tmux",
        session_kind: "codex",
        control_mode: "managed",
        work_state: "blocked",
        action: "operator-needed",
        summary: "needs operator input",
        fingerprint: "fp-test",
        payload: Jason.encode!(%{reason: "blocked"})
      })
      |> Repo.insert!()

    signal = MonitorEvents.to_signal(event)

    assert signal.type == "session.blocked"
    assert signal.subject == "session-1"
    assert signal.data.project == "saysure"
    assert signal.data.payload == %{"reason" => "blocked"}
  end

  test "daemon health alerts are persisted and notifiable" do
    now = DateTime.utc_now()

    assert {:ok, _heartbeat} =
             OrchestratorHeartbeats.upsert(%{
               daemon_key: "daemon-test",
               consumer: "orchestrator",
               status: "running",
               last_scan_at: DateTime.add(now, -420, :second),
               next_wake_at: DateTime.add(now, -300, :second),
               scan_snapshot: "{}"
             })

    alerts = OrchestratorHeartbeats.health_alerts(now: now, stale_after_seconds: 60)

    assert [%{kind: "orchestrator.health", reason: "stale", severity: "warning"}] = alerts

    assert {:ok, [event]} = MonitorEvents.record_scan(%{daemon_health_alerts: alerts})
    assert event.kind == "orchestrator.health"
    assert event.ref == "daemon-test"

    assert %{saved: 1, notifications: [notification]} = Notifications.record_events([event])
    assert notification.kind == "orchestrator.health"
  end
end
