defmodule JX.WakeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JX.CLI
  alias JX.CallBrief
  alias JX.CallHandoffs.CallHandoff
  alias JX.CiWatches.CiWatch
  alias JX.Delegations.Delegation
  alias JX.MonitorEvents.Event
  alias JX.Notifications.Notification
  alias JX.Repo
  alias JX.WakeTriggers.WakeTrigger
  alias JX.Workspace

  setup do
    Repo.delete_all(WakeTrigger)
    Repo.delete_all(Notification)
    Repo.delete_all(Event)
    Repo.delete_all(CallHandoff)
    Repo.delete_all(Delegation)
    Repo.delete_all(CiWatch)

    on_exit(fn ->
      Repo.delete_all(WakeTrigger)
      Repo.delete_all(Notification)
      Repo.delete_all(Event)
      Repo.delete_all(CallHandoff)
      Repo.delete_all(Delegation)
      Repo.delete_all(CiWatch)
    end)

    :ok
  end

  test "workspace wake records a monitor event and notification" do
    assert {:ok, result} =
             Workspace.wake(%{
               message: "external incident opened",
               project: "saysure",
               ref: "s-123",
               severity: "notice"
             })

    assert result.wake_id =~ "wak-"
    assert [%Event{kind: "external.wake", summary: "external incident opened"}] = result.events
    assert result.notifications.saved == 1

    assert [
             %Notification{
               kind: "external.wake",
               severity: "notice",
               summary: "external incident opened",
               project: "saysure",
               ref: "s-123"
             }
           ] = Repo.all(Notification)
  end

  test "wake notifications appear in call brief agenda" do
    {:ok, _result} = Workspace.wake(%{message: "review webhook payload", severity: "notice"})

    notification = Repo.one!(Notification)

    brief =
      CallBrief.build(%{
        notifications: [notification],
        inbox: %{},
        portfolio: %{},
        heartbeats: []
      })

    assert [%{kind: "notification", label: "review webhook payload"}] = brief.agenda
    assert brief.next =~ "Review notification"
  end

  test "CLI wake records durable external wake" do
    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "wake",
                   "--message",
                   "script requested attention",
                   "--severity",
                   "warning"
                 ])
      end)

    assert output =~ "wake wak-"
    assert output =~ "external.wake warning"
    assert Repo.aggregate(Notification, :count) == 1
  end

  test "workspace runs due one-shot wake triggers" do
    now = DateTime.utc_now()

    assert {:ok, trigger} =
             Workspace.add_wake_trigger(%{
               message: "scheduled incident review",
               project: "saysure",
               ref: "s-456",
               severity: "warning",
               schedule: "once",
               next_run_at: DateTime.add(now, -1, :second)
             })

    assert trigger.trigger_id =~ "wtr-"

    assert {:ok, report} = Workspace.run_due_wake_triggers(now: now, limit: 5)
    assert report.total == 1
    assert report.notifications_saved == 1
    assert report.errors == []

    assert [
             %{
               status: "emitted",
               trigger: %WakeTrigger{status: "completed", run_count: 1},
               wake: %{
                 events: [%Event{kind: "external.wake", summary: "scheduled incident review"}]
               }
             }
           ] = report.runs

    stored = Repo.get!(WakeTrigger, trigger.id)
    assert stored.status == "completed"
    assert stored.next_run_at == nil
    assert Repo.aggregate(Notification, :count) == 1
  end

  test "workspace reschedules recurring wake triggers" do
    now = DateTime.utc_now()

    assert {:ok, trigger} =
             Workspace.add_wake_trigger(%{
               message: "recurring project review",
               severity: "notice",
               schedule: "every",
               every_seconds: 300,
               next_run_at: DateTime.add(now, -1, :second)
             })

    assert {:ok, report} = Workspace.run_due_wake_triggers(now: now, limit: 5)

    assert [
             %{
               status: "emitted",
               trigger: %WakeTrigger{status: "active", run_count: 1} = updated
             }
           ] = report.runs

    assert updated.trigger_id == trigger.trigger_id
    assert DateTime.compare(updated.next_run_at, DateTime.add(now, 300, :second)) == :eq
  end

  test "monitor scan runs due wake triggers for daemon-style polling" do
    now = DateTime.utc_now()

    assert {:ok, _trigger} =
             Workspace.add_wake_trigger(%{
               message: "daemon picked up scheduled wake",
               severity: "warning",
               schedule: "once",
               next_run_at: DateTime.add(now, -1, :second)
             })

    assert {:ok, scan} = Workspace.monitor_scan(observe: false, type: "agent")
    assert scan.wake_triggers_total == 1
    assert scan.wake_notifications_saved == 1
    assert [%{status: "emitted", trigger: %WakeTrigger{status: "completed"}}] = scan.wake_triggers

    assert 1 ==
             Notification
             |> Repo.all()
             |> Enum.count(&(&1.kind == "external.wake"))
  end

  test "CLI manages scheduled wake triggers" do
    past = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.to_iso8601()

    add_output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "wake",
                   "add",
                   "--message",
                   "cli scheduled wake",
                   "--at",
                   past,
                   "--json"
                 ])
      end)

    assert %{"trigger" => %{"trigger_id" => trigger_id, "status" => "active"}} =
             Jason.decode!(add_output)

    list_output =
      capture_io(fn ->
        assert :ok = CLI.run(["wake", "ls", "--status", "active", "--json"])
      end)

    assert %{"triggers" => [%{"trigger_id" => ^trigger_id}]} = Jason.decode!(list_output)

    due_output =
      capture_io(fn ->
        assert :ok = CLI.run(["wake", "run-due", "--json"])
      end)

    assert %{
             "total" => 1,
             "runs" => [
               %{
                 "status" => "emitted",
                 "trigger" => %{"trigger_id" => ^trigger_id, "status" => "completed"}
               }
             ]
           } = Jason.decode!(due_output)
  end
end
