defmodule JX.ApprovalsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JX.Approvals
  alias JX.Approvals.Approval
  alias JX.CLI
  alias JX.DevIDE.{Portfolio, State, Status, WorkspaceSnapshot}
  alias JX.MonitorEvents.Event
  alias JX.Notifications.Notification
  alias JX.Notifications.FileSink
  alias JX.Repo
  alias JX.Workspace
  alias JXTest.Fixtures

  setup do
    cleanup_state()
    :ok
  end

  test "DevIDE blocked transitions create deduplicated approval items" do
    first = portfolio("status_ws1_watch_healthy.json")
    second = portfolio("status_ws1_watch_blocked.json")

    assert %{approvals: %{saved: 0}} = State.ingest_portfolio(first)
    assert %{approvals: %{saved: 3, duplicates: 0}} = State.ingest_portfolio(second)
    assert %{approvals: %{saved: 0}} = State.ingest_portfolio(second)

    approvals = Approvals.list(status: "all", limit: 10)

    assert approvals |> Enum.map(& &1.kind) |> Enum.sort() ==
             ~w(failed_run proposal_conflict unsafe_db)

    assert Enum.all?(approvals, &(&1.source == "devide"))
    assert Enum.all?(approvals, &(&1.workspace_id == "ws-1"))
    assert Repo.aggregate(Approval, :count) == 3
  end

  test "approval notifications route new items, escalations, and repeated failures without duplicate spam" do
    path = configure_file_sink!()

    unsafe_warning = notification("unsafe-warning", "warning", unsafe_snapshot())
    unsafe_critical = notification("unsafe-critical", "critical", unsafe_snapshot())

    assert %{saved: 1, duplicates: 0, routed: %{delivered: 1}} =
             Approvals.record_devide_notifications([unsafe_warning])

    assert read_sink_events(path) |> Enum.map(& &1["event"]) == ["approval.created"]

    assert %{saved: 0, duplicates: 1, routed: %{delivered: 0}} =
             Approvals.record_devide_notifications([unsafe_warning])

    assert read_sink_events(path) |> length() == 1

    assert %{saved: 0, duplicates: 1, routed: %{delivered: 1}} =
             Approvals.record_devide_notifications([unsafe_critical])

    assert read_sink_events(path) |> Enum.map(& &1["event"]) ==
             ["approval.created", "approval.severity_escalated"]

    assert Repo.get_by!(Approval, kind: "unsafe_db").severity == "critical"

    failure_one = notification("failed-one", "warning", failed_run_snapshot("run-1"))
    failure_two = notification("failed-two", "warning", failed_run_snapshot("run-2"))
    failure_three = notification("failed-three", "critical", failed_run_snapshot("run-3"))

    assert %{saved: 1, routed: %{delivered: 1}} =
             Approvals.record_devide_notifications([failure_one])

    assert %{saved: 0, duplicates: 1, routed: %{delivered: 0}} =
             Approvals.record_devide_notifications([failure_one])

    assert %{saved: 0, duplicates: 1, routed: %{delivered: 1}} =
             Approvals.record_devide_notifications([failure_two])

    assert %{saved: 0, duplicates: 1, routed: %{delivered: 2}} =
             Approvals.record_devide_notifications([failure_three])

    assert read_sink_events(path) |> Enum.map(& &1["event"]) ==
             [
               "approval.created",
               "approval.severity_escalated",
               "approval.created",
               "approval.repeated_failure",
               "approval.severity_escalated",
               "approval.repeated_failure"
             ]
  end

  test "policy blocked DevIDE transitions create policy approval items" do
    status =
      Status.from_payload(
        Fixtures.devide_payload("status_blocked_shared_stage.json"),
        Fixtures.devide_payload("runs_success.json"),
        Fixtures.devide_payload("proposals_empty.json"),
        Fixtures.devide_payload("audit_policy_blocked.json")
      )

    State.ingest_portfolio(Portfolio.from_statuses([status]))

    assert [%Approval{kind: "policy_blocked", status: "open"}] =
             Approvals.list(kind: "policy_blocked", status: "open")
  end

  test "ack keeps approval active and dismiss closes it" do
    State.ingest_portfolio(portfolio("status_ws1_watch_blocked.json"))
    approval = Approvals.list(kind: "unsafe_db") |> List.first()

    assert {:ok, acknowledged} = Approvals.acknowledge(approval.approval_id)
    assert acknowledged.status == "acknowledged"
    assert acknowledged.acknowledged_at
    assert Enum.any?(Approvals.list(), &(&1.approval_id == approval.approval_id))

    assert {:ok, dismissed} = Approvals.dismiss(approval.approval_id)
    assert dismissed.status == "dismissed"
    assert dismissed.dismissed_at
    refute Enum.any?(Approvals.list(), &(&1.approval_id == approval.approval_id))
  end

  test "portfolio summary exposes open approval counts" do
    State.ingest_portfolio(portfolio("status_ws1_watch_blocked.json"))

    assert {:ok, summary} = Workspace.portfolio_summary(observe: false)
    assert summary.totals.open_approvals == 3
    assert summary.totals.devide_open_approvals == 3
    assert summary.approvals.open_total == 3
  end

  test "approval CLI can list, show, ack, and dismiss without DevIDE calls" do
    State.ingest_portfolio(portfolio("status_ws1_watch_blocked.json"))
    approval = Approvals.list(kind: "unsafe_db") |> List.first()

    list_output = capture_io(fn -> assert :ok = CLI.run(["approvals", "ls"]) end)
    assert list_output =~ approval.approval_id
    assert list_output =~ "unsafe_db"

    show_output =
      capture_io(fn -> assert :ok = CLI.run(["approvals", "show", approval.approval_id]) end)

    assert show_output =~ "workspace summary"
    assert show_output =~ "reason/severity"
    assert show_output =~ "related DevIDE refs"
    assert show_output =~ "latest command runs"
    assert show_output =~ "proposal risk summary"
    assert show_output =~ "db isolation/policy mode"
    assert show_output =~ "suggested next safe action"
    assert show_output =~ "id: ws-1"
    assert show_output =~ "kind: unsafe_db"
    assert show_output =~ "Run `jx devide status ws-1`."

    ack_output =
      capture_io(fn -> assert :ok = CLI.run(["approvals", "ack", approval.approval_id]) end)

    assert ack_output =~ "acknowledged #{approval.approval_id}"
    assert Repo.get_by!(Approval, approval_id: approval.approval_id).status == "acknowledged"

    dismiss_output =
      capture_io(fn -> assert :ok = CLI.run(["approvals", "dismiss", approval.approval_id]) end)

    assert dismiss_output =~ "dismissed #{approval.approval_id}"
    assert Repo.get_by!(Approval, approval_id: approval.approval_id).status == "dismissed"
  end

  test "approval detail refreshes evidence from latest stored DevIDE snapshot" do
    State.ingest_portfolio(portfolio("status_ws1_watch_blocked.json"))
    approval = Approvals.list(kind: "unsafe_db") |> List.first()

    State.ingest_portfolio(portfolio("status_ws1_watch_healthy.json"))

    assert {:ok, detail} = Approvals.detail(approval.approval_id)
    assert detail.evidence.source == "stored_devide_snapshot"
    assert detail.evidence.workspace.status == "healthy"
    assert detail.evidence.workspace.db_isolation == "local"
    assert detail.evidence.related.db_isolation == "unsafe"
  end

  test "approval detail degrades with missing evidence and redacts secrets" do
    approval =
      insert_approval!(%{
        approval_id: "apr-secret",
        workspace_id: "missing",
        kind: "failed_run",
        target_ref: "test",
        summary: "Failed run needs review",
        metadata:
          Jason.encode!(%{
            "run" => %{
              "command_id" => "mix test --token=super-secret",
              "status" => "failed"
            },
            "evidence" => %{
              "snapshot" => %{
                "id" => "missing",
                "latest_runs" => [
                  %{"command_id" => "mix test --token=super-secret", "status" => "failed"}
                ],
                "api_token" => "super-secret"
              }
            }
          })
      })

    assert {:ok, detail} = Approvals.detail(approval.approval_id)
    assert detail.evidence.source == "approval_metadata"
    assert "stored_workspace_snapshot" in detail.evidence.missing

    output =
      capture_io(fn -> assert :ok = CLI.run(["approvals", "show", approval.approval_id]) end)

    refute output =~ "super-secret"
    assert output =~ "<redacted>"
  end

  defp portfolio(status_fixture) do
    status_fixture
    |> Fixtures.devide_payload()
    |> Status.from_payload()
    |> then(&Portfolio.from_statuses([&1]))
  end

  defp cleanup_state do
    Repo.delete_all(Approval)
    Repo.delete_all(Notification)
    Repo.delete_all(Event)
    Repo.delete_all(WorkspaceSnapshot)
  end

  defp configure_file_sink! do
    previous = Application.get_env(:jx, :notification_sinks)

    state_dir =
      Path.join(System.tmp_dir!(), "jx-approval-sink-#{System.unique_integer([:positive])}")

    path = Path.join(state_dir, "approvals.jsonl")

    Application.put_env(:jx, :notification_sinks, [{FileSink, [path: path, state_dir: state_dir]}])

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:jx, :notification_sinks)
      else
        Application.put_env(:jx, :notification_sinks, previous)
      end

      File.rm_rf(state_dir)
    end)

    path
  end

  defp read_sink_events(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        {:ok, payload} = Jason.decode(line)
        payload
      end)
    else
      []
    end
  end

  defp notification(id, severity, snapshot) do
    %Notification{
      notification_id: "ntf-#{id}",
      source_event_id: "evt-#{id}",
      kind: "devide.workspace.blocked",
      severity: severity,
      ref: "ws-1",
      project: "alpha",
      summary: "DevIDE workspace needs attention",
      payload:
        Jason.encode!(%{
          "id" => "ws-1",
          "current" => %{
            "id" => "ws-1",
            "name" => "alpha",
            "status" => Map.get(snapshot, "status", "blocked"),
            "db_isolation" => Map.get(snapshot, "db_isolation", "local"),
            "snapshot" => snapshot
          }
        })
    }
  end

  defp unsafe_snapshot do
    %{
      "id" => "ws-1",
      "name" => "alpha",
      "status" => "blocked",
      "db_isolation" => "unsafe",
      "latest_runs" => [],
      "proposal_risks" => [],
      "recent_blocks" => [],
      "attention_flags" => ["db_isolation:unsafe"]
    }
  end

  defp failed_run_snapshot(run_id) do
    %{
      "id" => "ws-1",
      "name" => "alpha",
      "status" => "blocked",
      "db_isolation" => "local",
      "active_run" => %{
        "id" => run_id,
        "command_id" => "test",
        "status" => "failed",
        "exit_code" => "1"
      },
      "latest_runs" => [],
      "proposal_risks" => [],
      "recent_blocks" => [],
      "attention_flags" => ["active_run:failed"]
    }
  end

  defp insert_approval!(attrs) do
    defaults = %{
      source: "devide",
      severity: "warning",
      status: "open",
      metadata: "{}",
      dedupe_key: "test-#{Map.fetch!(attrs, :approval_id)}"
    }

    %Approval{}
    |> Approval.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end
