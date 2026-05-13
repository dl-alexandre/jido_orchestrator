defmodule JX.ControlPlaneTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias JX.Approvals.Approval
  alias JX.ControlPlane
  alias JX.DelegatedExecution
  alias JX.DelegatedExecution.{Assignment, Runner, RunnerSession}
  alias JX.OperationalEvents
  alias JX.OperationalEvents.Event, as: OperationalEvent
  alias JX.OperationalLeases.Lease
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Repo
  alias JX.SafeActions

  setup do
    cleanup_state()
    :ok
  end

  test "dashboard_runner returns error for non-existent runner" do
    assert {:error, :runner_not_found} =
             ControlPlane.dashboard_runner("nonexistent-runner", now: DateTime.utc_now())
  end

  test "dashboard_assignment returns error for non-existent assignment" do
    assert {:error, :assignment_not_found} =
             ControlPlane.dashboard_assignment("nonexistent-assignment",
               now: DateTime.utc_now()
             )
  end

  test "dashboard_action returns error for non-existent action" do
    assert {:error, _reason} =
             ControlPlane.dashboard_action("nonexistent-action", now: DateTime.utc_now())
  end

  test "queue sorts by freshness, owner, and risk" do
    now = DateTime.utc_now()

    insert_snapshot!("ws-fresh", status: "healthy", observed_at: now)

    insert_snapshot!("ws-stale",
      status: "healthy",
      observed_at: DateTime.add(now, -1_200, :second)
    )

    insert_approval!("apr-risky",
      workspace_id: "ws-fresh",
      kind: "proposal_conflict",
      command_id: "test"
    )

    {:ok, _event} =
      OperationalEvents.record_workspace_snapshot(snapshot("ws-fresh"), "devide.snapshot.changed")

    {:ok, _event} =
      OperationalEvents.record_workspace_snapshot(snapshot("ws-stale"), "devide.snapshot.changed")

    {:ok, _event} = OperationalEvents.record_approval(approval("apr-risky"), "approval.created")

    urgency_queue =
      ControlPlane.queue(now: now, sort: "urgency", stale_after_seconds: 600, limit: 50)

    assert length(urgency_queue.items) > 0

    freshness_queue =
      ControlPlane.queue(now: now, sort: "freshness", stale_after_seconds: 600, limit: 50)

    assert length(freshness_queue.items) > 0

    owner_queue = ControlPlane.queue(now: now, sort: "owner", stale_after_seconds: 600, limit: 50)
    assert length(owner_queue.items) > 0

    risk_queue = ControlPlane.queue(now: now, sort: "risk", stale_after_seconds: 600, limit: 50)
    assert length(risk_queue.items) > 0
  end

  test "queue covers workspace risk and reason for needs_review and unknown statuses" do
    now = DateTime.utc_now()

    insert_snapshot!("ws-needs-review",
      status: "needs_review",
      observed_at: now
    )

    insert_snapshot!("ws-unknown",
      status: "unknown",
      observed_at: now
    )

    {:ok, _event} =
      OperationalEvents.record_workspace_snapshot(
        snapshot("ws-needs-review"),
        "devide.snapshot.changed"
      )

    {:ok, _event} =
      OperationalEvents.record_workspace_snapshot(
        snapshot("ws-unknown"),
        "devide.snapshot.changed"
      )

    queue = ControlPlane.queue(now: now, stale_after_seconds: 600, limit: 50)

    assert Enum.any?(
             queue.items,
             &match?(%{type: "workspace", id: "ws-needs-review", risk: "risky"}, &1)
           )

    assert Enum.any?(
             queue.items,
             &match?(%{type: "workspace", id: "ws-unknown", risk: "stale"}, &1)
           )
  end

  test "queue covers approval risk for unsafe_db, policy_blocked, and proposal_conflict" do
    now = DateTime.utc_now()

    insert_snapshot!("ws-approvals", status: "healthy", observed_at: now)

    insert_approval!("apr-unsafe",
      workspace_id: "ws-approvals",
      kind: "unsafe_db",
      command_id: "test-unsafe"
    )

    insert_approval!("apr-policy",
      workspace_id: "ws-approvals",
      kind: "policy_blocked",
      command_id: "test-policy"
    )

    insert_approval!("apr-proposal",
      workspace_id: "ws-approvals",
      kind: "proposal_conflict",
      command_id: "test-proposal"
    )

    {:ok, _event} =
      OperationalEvents.record_workspace_snapshot(
        snapshot("ws-approvals"),
        "devide.snapshot.changed"
      )

    {:ok, _event} = OperationalEvents.record_approval(approval("apr-unsafe"), "approval.created")
    {:ok, _event} = OperationalEvents.record_approval(approval("apr-policy"), "approval.created")

    {:ok, _event} =
      OperationalEvents.record_approval(approval("apr-proposal"), "approval.created")

    queue = ControlPlane.queue(now: now, stale_after_seconds: 600, limit: 50)

    assert Enum.any?(
             queue.items,
             &match?(%{type: "approval", id: "apr-unsafe", risk: "blocked"}, &1)
           )

    assert Enum.any?(
             queue.items,
             &match?(%{type: "approval", id: "apr-policy", risk: "blocked"}, &1)
           )

    assert Enum.any?(
             queue.items,
             &match?(%{type: "approval", id: "apr-proposal", risk: "risky"}, &1)
           )
  end

  test "queue covers assignment and runner_session risk paths for failed, expired, and stale" do
    now = DateTime.utc_now()

    insert_snapshot!("ws-assignments", status: "healthy", observed_at: now)
    action = planned_action!("ws-assignments", "apr-assignments", "test")

    assert {:ok, assignment} =
             DelegatedExecution.create_assignment(action.action_id, now: now, ttl_seconds: 1)

    assert {:ok, _runner} =
             DelegatedExecution.register_runner(%{
               runner_id: "runner-test",
               agent_id: "agent-test",
               workspace_affinity: ["ws-assignments"],
               capabilities: ["safe_action:rerun_devide_command"],
               now: now,
               heartbeat_ttl_seconds: 1
             })

    assert {:ok, %{assignment: _claimed, session: session}} =
             DelegatedExecution.claim_runner_assignment(
               assignment.assignment_id,
               "runner-test",
               session_id: "session-test",
               now: now,
               ttl_seconds: 1
             )

    later = DateTime.add(now, 3, :second)

    assert [%Assignment{status: "expired"}] = DelegatedExecution.expire_assignments(now: later)

    assert [%RunnerSession{status: "expired"}] =
             DelegatedExecution.expire_runner_sessions(now: later)

    queue = ControlPlane.queue(now: later, stale_after_seconds: 600, limit: 50)

    assignment_id = assignment.assignment_id

    assert Enum.any?(
             queue.items,
             &match?(%{type: "assignment", id: ^assignment_id, risk: "stale"}, &1)
           )

    session_id = session.session_id

    assert Enum.any?(
             queue.items,
             &match?(%{type: "session", id: ^session_id, risk: "stale"}, &1)
           )
  end

  test "queue covers action_reason for error status and stale freshness" do
    now = DateTime.utc_now()

    insert_snapshot!("ws-action", status: "healthy", observed_at: now)

    approval =
      insert_approval!("apr-action",
        workspace_id: "ws-action",
        kind: "failed_run",
        command_id: "test"
      )

    assert {:ok, proposed} = SafeActions.propose(approval.approval_id, owner: "test")
    action_id = proposed.action.action_id

    Repo.update_all(
      from(a in OrchestrationAction, where: a.action_id == ^action_id),
      set: [status: "error", outcome_reason: "connection refused"]
    )

    {:ok, _event} =
      OperationalEvents.record_workspace_snapshot(
        snapshot("ws-action"),
        "devide.snapshot.changed"
      )

    {:ok, _event} = OperationalEvents.record_approval(approval("apr-action"), "approval.created")

    queue = ControlPlane.queue(now: now, stale_after_seconds: 600, limit: 50)

    assert Enum.any?(
             queue.items,
             &match?(%{type: "action", id: ^action_id, risk: "blocked"}, &1)
           )
  end

  test "queue handles actions with bad payload and bad expires_at" do
    now = DateTime.utc_now()

    insert_snapshot!("ws-bad-payload", status: "healthy", observed_at: now)

    approval =
      insert_approval!("apr-bad",
        workspace_id: "ws-bad-payload",
        kind: "failed_run",
        command_id: "test"
      )

    assert {:ok, proposed} = SafeActions.propose(approval.approval_id, owner: "test")
    action_id = proposed.action.action_id

    Repo.update_all(
      from(a in OrchestrationAction, where: a.action_id == ^action_id),
      set: [payload: "not json", status: "planned"]
    )

    {:ok, _event} =
      OperationalEvents.record_workspace_snapshot(
        snapshot("ws-bad-payload"),
        "devide.snapshot.changed"
      )

    {:ok, _event} = OperationalEvents.record_approval(approval("apr-bad"), "approval.created")

    queue = ControlPlane.queue(now: now, stale_after_seconds: 600, limit: 50)

    assert Enum.any?(
             queue.items,
             &match?(%{type: "action", id: ^action_id}, &1)
           )
  end

  test "queue handles items with unknown urgency and freshness ranks" do
    now = DateTime.utc_now()

    insert_snapshot!("ws-info", status: "healthy", observed_at: now)

    approval =
      insert_approval!("apr-info",
        workspace_id: "ws-info",
        kind: "failed_run",
        command_id: "test"
      )

    approval_id = approval.approval_id

    Repo.update_all(
      from(a in Approval, where: a.approval_id == ^approval_id),
      set: [severity: "info"]
    )

    {:ok, _event} =
      OperationalEvents.record_workspace_snapshot(snapshot("ws-info"), "devide.snapshot.changed")

    {:ok, _event} =
      OperationalEvents.record_approval(
        Repo.get_by!(Approval, approval_id: approval_id),
        "approval.created"
      )

    queue = ControlPlane.queue(now: now, stale_after_seconds: 600, limit: 50)

    assert Enum.any?(
             queue.items,
             &match?(%{type: "approval", id: ^approval_id, urgency: "info"}, &1)
           )
  end

  defp insert_snapshot!(workspace_id, opts) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
    status = Keyword.fetch!(opts, :status)

    snapshot = %{
      id: workspace_id,
      name: "Workspace #{workspace_id}",
      status: status,
      lifecycle_status: "running",
      mode: "review",
      db_isolation: "local",
      active_run: nil,
      latest_runs: [%{command_id: "test", status: "failed"}],
      proposal_risks: [],
      recent_blocks: [],
      attention_flags: []
    }

    %JX.DevIDE.WorkspaceSnapshot{}
    |> JX.DevIDE.WorkspaceSnapshot.changeset(%{
      workspace_id: workspace_id,
      name: "Workspace #{workspace_id}",
      lifecycle_status: "running",
      status: status,
      mode: "review",
      db_isolation: "local",
      attention_flags: Jason.encode!([]),
      snapshot: Jason.encode!(snapshot),
      fingerprint: "fp-#{workspace_id}-#{System.unique_integer([:positive])}",
      source_url: "http://devide.local",
      last_observed_at: observed_at,
      last_changed_at: observed_at
    })
    |> Repo.insert!()
  end

  defp snapshot(workspace_id) do
    Repo.get_by!(JX.DevIDE.WorkspaceSnapshot, workspace_id: workspace_id)
  end

  defp insert_approval!(approval_id, opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    kind = Keyword.fetch!(opts, :kind)
    command_id = Keyword.fetch!(opts, :command_id)
    target_ref = Keyword.get(opts, :target_ref, command_id)

    %Approval{}
    |> Approval.changeset(%{
      approval_id: approval_id,
      source: "devide",
      workspace_id: workspace_id,
      kind: kind,
      severity: "warning",
      target_ref: target_ref,
      summary: "DevIDE workspace #{workspace_id} has #{target_ref} #{kind}",
      status: "open",
      metadata:
        Jason.encode!(%{
          "run" => %{
            "id" => "run-#{command_id}",
            "command_id" => command_id,
            "status" => "failed"
          }
        }),
      dedupe_key: "dedupe-#{approval_id}"
    })
    |> Repo.insert!()
  end

  defp approval(approval_id) do
    Repo.get_by!(Approval, approval_id: approval_id)
  end

  defp planned_action!(workspace_id, approval_id, command_id) do
    %Approval{}
    |> Approval.changeset(%{
      approval_id: approval_id,
      source: "devide",
      workspace_id: workspace_id,
      kind: "failed_run",
      severity: "warning",
      target_ref: command_id,
      summary: "DevIDE workspace #{workspace_id} has #{command_id} failed_run",
      status: "open",
      metadata:
        Jason.encode!(%{
          "run" => %{
            "id" => "run-#{command_id}",
            "command_id" => command_id,
            "status" => "failed"
          }
        }),
      dedupe_key: "dedupe-#{approval_id}"
    })
    |> Repo.insert!()
    |> then(fn approval ->
      assert {:ok, proposed} = SafeActions.propose(approval.approval_id, owner: "test")
      proposed.action
    end)
  end

  defp cleanup_state do
    Repo.delete_all(OperationalEvent)
    Repo.delete_all(Lease)
    Repo.delete_all(JX.SafeActions.ExecutionEvent)
    Repo.delete_all(OrchestrationAction)
    Repo.delete_all(Approval)
    Repo.delete_all(JX.Notifications.Notification)
    Repo.delete_all(JX.MonitorEvents.Event)
    Repo.delete_all(JX.DevIDE.WorkspaceSnapshot)
    Repo.delete_all(Assignment)
    Repo.delete_all(RunnerSession)
    Repo.delete_all(Runner)
    Repo.delete_all(DelegatedExecution.Agent)
  end
end
