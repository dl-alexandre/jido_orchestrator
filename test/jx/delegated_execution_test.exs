defmodule JX.DelegatedExecutionTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias JX.Approvals.Approval
  alias JX.CLI
  alias JX.DelegatedExecution
  alias JX.DelegatedExecution.{Agent, Assignment, Report, Runner, RunnerReport, RunnerSession}
  alias JX.DevIDE.{Client, RunnerReconciler, WorkspaceSnapshot}
  alias JX.MonitorEvents.Event, as: MonitorEvent
  alias JX.Notifications.Notification
  alias JX.OperationExecutions.OperationExecution
  alias JX.OperationalEvents.Event, as: OperationalEvent
  alias JX.OperationalLeases.Lease
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Repo
  alias JX.SafeActions
  alias JX.SafeActions.ExecutionEvent
  alias JX.Workspace

  @token "delegated-token"
  @capability "safe_action:rerun_devide_command"

  setup do
    cleanup_state()
    :ok
  end

  test "agent claims enforce capability, workspace affinity, and live heartbeat" do
    now = DateTime.utc_now()
    action = planned_action!("ws-claim", "apr-claim", "test")
    assert {:ok, assignment} = DelegatedExecution.create_assignment(action.action_id, now: now)

    assert {:ok, _agent} =
             DelegatedExecution.register_agent(%{
               agent_id: "agent-missing-cap",
               capabilities: [],
               workspace_affinity: ["ws-claim"],
               now: now
             })

    assert {:error, {:agent_missing_capabilities, [@capability]}} =
             DelegatedExecution.claim_assignment(
               assignment.assignment_id,
               "agent-missing-cap",
               now: now
             )

    assert {:ok, _agent} =
             DelegatedExecution.register_agent(%{
               agent_id: "agent-wrong-workspace",
               capabilities: [@capability],
               workspace_affinity: ["other-workspace"],
               now: now
             })

    assert {:error, {:agent_workspace_mismatch, "ws-claim"}} =
             DelegatedExecution.claim_assignment(
               assignment.assignment_id,
               "agent-wrong-workspace",
               now: now
             )

    old_heartbeat = DateTime.add(now, -30, :second)

    assert {:ok, _agent} =
             DelegatedExecution.register_agent(%{
               agent_id: "agent-live",
               capabilities: [@capability],
               workspace_affinity: ["ws-claim"],
               heartbeat_ttl_seconds: 10,
               now: old_heartbeat
             })

    assert %{status: "stale"} =
             DelegatedExecution.list_agents(status: "all", now: now)
             |> Enum.find(&(&1.agent_id == "agent-live"))

    assert {:error, {:agent_stale, "agent-live"}} =
             DelegatedExecution.claim_assignment(assignment.assignment_id, "agent-live", now: now)

    assert {:ok, heartbeat} = DelegatedExecution.heartbeat("agent-live", now: now)
    assert heartbeat.status == "idle"

    assert {:ok, claimed} =
             DelegatedExecution.claim_assignment(assignment.assignment_id, "agent-live", now: now)

    assert claimed.status == "claimed"
    assert claimed.claimant_agent_id == "agent-live"

    assert %Lease{owner: "agent-live", status: "active"} =
             Repo.get_by!(Lease, lease_id: claimed.lease_id)

    assert %{status: "busy", active_assignments: 1} =
             DelegatedExecution.list_agents(status: "all", now: now)
             |> Enum.find(&(&1.agent_id == "agent-live"))
  end

  test "one assignment has one active claimant and stale work is safely recreated" do
    now = DateTime.utc_now()
    action = planned_action!("ws-exclusive", "apr-exclusive", "test")

    assert {:ok, first} =
             DelegatedExecution.create_assignment(action.action_id, now: now, ttl_seconds: 2)

    register_capable_agent!("agent-a", "ws-exclusive", now)
    register_capable_agent!("agent-b", "ws-exclusive", now)

    assert {:ok, claimed} =
             DelegatedExecution.claim_assignment(first.assignment_id, "agent-a",
               now: now,
               ttl_seconds: 2
             )

    assert {:error, {:lease_conflict, %Lease{owner: "agent-a"}}} =
             DelegatedExecution.claim_assignment(first.assignment_id, "agent-b", now: now)

    later = DateTime.add(now, 3, :second)

    assert [%Assignment{assignment_id: expired_id, status: "expired"}] =
             DelegatedExecution.expire_assignments(now: later)

    assert expired_id == first.assignment_id
    assert Repo.get_by!(Lease, lease_id: claimed.lease_id).status == "released"

    assert {:ok, replacement} =
             DelegatedExecution.create_assignment(action.action_id, now: later, ttl_seconds: 60)

    refute replacement.assignment_id == first.assignment_id

    assert {:ok, reclaimed} =
             DelegatedExecution.claim_assignment(replacement.assignment_id, "agent-b",
               now: later,
               ttl_seconds: 60
             )

    assert reclaimed.status == "claimed"
    assert reclaimed.claimant_agent_id == "agent-b"
  end

  test "delegated execute uses the narrow DevIDE run endpoint and correlates evidence" do
    now = DateTime.utc_now()
    action = planned_action!("ws-run", "apr-run", "test")
    correlation_id = action |> action_payload() |> Map.fetch!("correlation_id")

    assert {:ok, assignment} = DelegatedExecution.create_assignment(action.action_id, now: now)
    register_capable_agent!("agent-runner", "ws-run", now)

    assert {:ok, claimed} =
             DelegatedExecution.claim_assignment(assignment.assignment_id, "agent-runner",
               now: now
             )

    assert {:ok, _started} =
             DelegatedExecution.start_assignment(
               assignment.assignment_id,
               "agent-runner",
               now: DateTime.add(now, 1, :second)
             )

    assert {:ok, _progressed} =
             DelegatedExecution.progress_assignment(
               assignment.assignment_id,
               "agent-runner",
               "ready to rerun",
               now: DateTime.add(now, 2, :second)
             )

    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: @token)

    Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-run/runs", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      assert Plug.Conn.get_req_header(conn, "x-jx-correlation-id") == [correlation_id]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"command_id" => "test"}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        201,
        Jason.encode!(%{
          id: "run-delegated",
          workspace_id: "ws-run",
          command_id: "test",
          status: "running"
        })
      )
    end)

    assert {:ok, completed} =
             DelegatedExecution.execute_assignment(
               assignment.assignment_id,
               "agent-runner",
               confirm: true,
               client: client,
               now: DateTime.add(now, 3, :second)
             )

    assert completed.status == "completed"
    assert completed.summary =~ "run-delegated"
    assert Repo.get_by!(Approval, approval_id: "apr-run").status == "acknowledged"
    assert Repo.get_by!(OrchestrationAction, action_id: action.action_id).status == "executed"
    assert Repo.get_by!(Lease, lease_id: claimed.lease_id).status == "released"

    assert [
             "assignment.created",
             "assignment.claimed",
             "assignment.started",
             "assignment.progressed",
             "assignment.completed"
           ] =
             assignment.assignment_id
             |> reports_for_assignment()
             |> Enum.map(& &1.kind)

    assert assignment.assignment_id
           |> reports_for_assignment()
           |> Enum.all?(&(&1.correlation_id == correlation_id))

    assert [
             "assignment.created",
             "assignment.claimed",
             "assignment.started",
             "assignment.progressed",
             "assignment.completed"
           ] =
             assignment.assignment_id
             |> operational_events_for_assignment()
             |> Enum.map(& &1.kind)

    assert assignment.assignment_id
           |> operational_events_for_assignment()
           |> Enum.all?(&(&1.correlation_id == correlation_id))

    assert [
             "proposed",
             "execute_attempted",
             "executed",
             "approval_ack_attempted",
             "approval_acknowledged"
           ] =
             action.action_id
             |> safe_action_events()
             |> Enum.map(& &1.kind)

    assert {:error, {:assignment_not_executable, "completed"}} =
             DelegatedExecution.execute_assignment(
               assignment.assignment_id,
               "agent-runner",
               confirm: true,
               client: client
             )

    assert Repo.get_by!(Assignment, assignment_id: assignment.assignment_id).status == "completed"
  end

  test "policy denial fails the assignment and does not call DevIDE" do
    now = DateTime.utc_now()
    action = planned_action!("ws-denied", "apr-denied", "test")
    assert {:ok, assignment} = DelegatedExecution.create_assignment(action.action_id, now: now)
    register_capable_agent!("agent-denied", "ws-denied", now)

    assert {:ok, claimed} =
             DelegatedExecution.claim_assignment(assignment.assignment_id, "agent-denied",
               now: now
             )

    Repo.get_by!(WorkspaceSnapshot, workspace_id: "ws-denied")
    |> WorkspaceSnapshot.changeset(%{
      db_isolation: "unsafe",
      fingerprint: "unsafe-now",
      snapshot: Jason.encode!(%{"id" => "ws-denied", "db_isolation" => "unsafe"})
    })
    |> Repo.update!()

    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: @token)
    {:ok, requests} = Elixir.Agent.start_link(fn -> [] end)

    Bypass.stub(bypass, "POST", "/api/workspaces/ws-denied/runs", fn conn ->
      Elixir.Agent.update(requests, &[conn.request_path | &1])
      Plug.Conn.resp(conn, 500, "unexpected")
    end)

    assert {:error, {:unsafe_db_isolation, "unsafe"}} =
             DelegatedExecution.execute_assignment(
               assignment.assignment_id,
               "agent-denied",
               confirm: true,
               client: client,
               now: DateTime.add(now, 1, :second)
             )

    assert Elixir.Agent.get(requests, & &1) == []
    assert Repo.get_by!(Assignment, assignment_id: assignment.assignment_id).status == "failed"
    assert Repo.get_by!(OrchestrationAction, action_id: action.action_id).status == "planned"
    assert Repo.get_by!(Lease, lease_id: claimed.lease_id).status == "released"
    assert List.last(safe_action_events(action.action_id)).outcome == "policy_denied"
  end

  test "multiple agents execute assignments across workspaces concurrently" do
    now = DateTime.utc_now()

    jobs = [
      %{
        workspace_id: "ws-alpha",
        approval_id: "apr-alpha",
        command_id: "test",
        agent_id: "agent-alpha"
      },
      %{
        workspace_id: "ws-beta",
        approval_id: "apr-beta",
        command_id: "compile",
        agent_id: "agent-beta"
      }
    ]

    assignments =
      Map.new(jobs, fn job ->
        action = planned_action!(job.workspace_id, job.approval_id, job.command_id)

        assert {:ok, assignment} =
                 DelegatedExecution.create_assignment(action.action_id,
                   created_by: "operator-#{job.agent_id}",
                   now: now
                 )

        register_capable_agent!(job.agent_id, job.workspace_id, now)
        {job.agent_id, {job, action, assignment}}
      end)

    claim_tasks =
      Enum.map(assignments, fn {agent_id, {_job, _action, assignment}} ->
        Task.async(fn ->
          DelegatedExecution.claim_assignment(assignment.assignment_id, agent_id, now: now)
        end)
      end)

    assert Enum.all?(Task.await_many(claim_tasks), &match?({:ok, %Assignment{}}, &1))

    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: @token)

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      case {conn.method, conn.request_path, decoded["command_id"]} do
        {"POST", "/api/workspaces/ws-alpha/runs", "test"} ->
          run_response(conn, "run-alpha", "ws-alpha", "test")

        {"POST", "/api/workspaces/ws-beta/runs", "compile"} ->
          run_response(conn, "run-beta", "ws-beta", "compile")
      end
    end)

    execute_tasks =
      Enum.map(assignments, fn {agent_id, {_job, _action, assignment}} ->
        Task.async(fn ->
          DelegatedExecution.execute_assignment(assignment.assignment_id, agent_id,
            confirm: true,
            client: client
          )
        end)
      end)

    assert Enum.all?(Task.await_many(execute_tasks, 10_000), fn
             {:ok, %Assignment{status: "completed"}} -> true
             _other -> false
           end)

    for {_agent_id, {job, action, assignment}} <- assignments do
      assert Repo.get_by!(Approval, approval_id: job.approval_id).status == "acknowledged"
      assert Repo.get_by!(OrchestrationAction, action_id: action.action_id).status == "executed"

      assert Repo.get_by!(Assignment, assignment_id: assignment.assignment_id).status ==
               "completed"
    end
  end

  test "runner registration creates host identity and exclusive assignment session ownership" do
    now = DateTime.utc_now()
    action = planned_action!("ws-runner", "apr-runner", "test")
    correlation_id = action |> action_payload() |> Map.fetch!("correlation_id")

    assert {:ok, assignment} =
             DelegatedExecution.create_assignment(action.action_id, now: now, ttl_seconds: 60)

    assert {:ok, runner} =
             DelegatedExecution.register_runner(%{
               runner_id: "runner-a",
               agent_id: "agent-runner-a",
               host_name: "host-a",
               capabilities: [@capability],
               workspace_affinity: ["ws-runner"],
               tmux_server: "jx",
               tmux_session_prefix: "jx-runner-a",
               now: now
             })

    assert runner.runner_id == "runner-a"
    assert Repo.get_by!(Agent, agent_id: "agent-runner-a").name == "agent-runner-a"

    assert {:ok, %{assignment: claimed, session: session}} =
             DelegatedExecution.claim_runner_assignment(
               assignment.assignment_id,
               "runner-a",
               session_id: "rsess-owned",
               tmux_session_name: "jx-owned",
               log_path: "/tmp/jx-owned.log",
               now: now,
               ttl_seconds: 60
             )

    assert claimed.status == "claimed"
    assert claimed.claimant_agent_id == "agent-runner-a"
    assert claimed.runner_id == "runner-a"
    assert claimed.session_id == "rsess-owned"

    assert session.status == "claimed"
    assert session.runner_id == "runner-a"
    assert session.agent_id == "agent-runner-a"
    assert session.assignment_id == assignment.assignment_id
    assert session.tmux_session_name == "jx-owned"
    assert session.log_path == "/tmp/jx-owned.log"
    assert session.correlation_id == correlation_id

    assert %Lease{owner: "agent-runner-a", status: "active"} =
             Repo.get_by!(Lease, lease_id: claimed.lease_id)

    assert {:ok, %{session: reconnected}} =
             DelegatedExecution.claim_runner_assignment(
               assignment.assignment_id,
               "runner-a",
               session_id: "ignored-new-session",
               now: DateTime.add(now, 1, :second)
             )

    assert reconnected.session_id == session.session_id
    assert reconnected.runner_id == "runner-a"

    assert {:ok, _runner_b} =
             DelegatedExecution.register_runner(%{
               runner_id: "runner-b",
               agent_id: "agent-runner-b",
               host_name: "host-b",
               capabilities: [@capability],
               workspace_affinity: ["ws-runner"],
               now: now
             })

    assert {:error, {:runner_session_conflict, %RunnerSession{session_id: "rsess-owned"}}} =
             DelegatedExecution.claim_runner_assignment(
               assignment.assignment_id,
               "runner-b",
               now: now
             )

    assert %{status: "busy", active_sessions: 1} =
             DelegatedExecution.list_runners(status: "all", now: now)
             |> Enum.find(&(&1.runner_id == "runner-a"))

    assert [
             "runner_session.created",
             "runner_session.claimed",
             "runner_session.reconnected",
             "runner_session.claimed"
           ] =
             session.session_id
             |> runner_reports_for_session()
             |> Enum.map(& &1.kind)

    assert session.session_id
           |> runner_reports_for_session()
           |> Enum.all?(&(&1.correlation_id == correlation_id))

    runner_timeline = Workspace.operational_timeline("runner", "runner-a", limit: 100)
    assert Enum.any?(runner_timeline.events, &(&1.kind == "runner.registered"))
    assert Enum.any?(runner_timeline.events, &(&1.kind == "runner_session.claimed"))

    rebuilt = Workspace.operational_rebuilt_state(limit: 1_000)
    assert rebuilt.state.runners["runner-a"].status == "idle"
    assert rebuilt.state.runner_sessions["rsess-owned"].status == "claimed"
    assert get_in(rebuilt.state.timelines, ["runner:runner-a"])
    assert get_in(rebuilt.state.timelines, ["session:rsess-owned"])
  end

  test "runner session executes through the existing safe-action DevIDE endpoint" do
    now = DateTime.utc_now()
    action = planned_action!("ws-runner-exec", "apr-runner-exec", "test")
    correlation_id = action |> action_payload() |> Map.fetch!("correlation_id")
    assert {:ok, assignment} = DelegatedExecution.create_assignment(action.action_id, now: now)

    register_capable_runner!("runner-exec", "agent-runner-exec", "ws-runner-exec", now)

    assert {:ok, %{session: session}} =
             DelegatedExecution.claim_runner_assignment(
               assignment.assignment_id,
               "runner-exec",
               session_id: "rsess-exec",
               now: now
             )

    assert {:ok, started} =
             DelegatedExecution.start_runner_session(
               session.session_id,
               "runner-exec",
               now: DateTime.add(now, 1, :second)
             )

    assert started.status == "running"

    assert {:ok, progressed} =
             DelegatedExecution.progress_runner_session(
               session.session_id,
               "runner-exec",
               "ready from tmux",
               now: DateTime.add(now, 2, :second)
             )

    assert progressed.status == "progressed"

    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: @token)

    Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-runner-exec/runs", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      assert Plug.Conn.get_req_header(conn, "x-jx-correlation-id") == [correlation_id]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"command_id" => "test"}
      run_response(conn, "run-runner-exec", "ws-runner-exec", "test")
    end)

    assert {:ok, completed} =
             DelegatedExecution.execute_runner_session(
               session.session_id,
               "runner-exec",
               confirm: true,
               client: client,
               now: DateTime.add(now, 3, :second)
             )

    assert completed.status == "completed"
    assert completed.active_assignment_key == nil
    assert Repo.get_by!(Assignment, assignment_id: assignment.assignment_id).status == "completed"
    assert Repo.get_by!(Approval, approval_id: "apr-runner-exec").status == "acknowledged"

    assert [
             "runner_session.created",
             "runner_session.claimed",
             "runner_session.started",
             "runner_session.progressed",
             "runner_session.completed"
           ] =
             session.session_id
             |> runner_reports_for_session()
             |> Enum.map(& &1.kind)

    assert session.session_id
           |> runner_reports_for_session()
           |> Enum.all?(&(&1.correlation_id == correlation_id))

    assert {:error, {:runner_session_closed, "completed"}} =
             DelegatedExecution.execute_runner_session(
               session.session_id,
               "runner-exec",
               confirm: true,
               client: client
             )
  end

  test "JX delegated assignments enqueue DevIDE runner assignments and reconcile replay idempotently" do
    now = DateTime.utc_now()
    action = planned_action!("ws-devide-runner", "apr-devide-runner", "test")
    correlation_id = action |> action_payload() |> Map.fetch!("correlation_id")
    assert {:ok, assignment} = DelegatedExecution.create_assignment(action.action_id, now: now)

    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: @token)

    Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-devide-runner/runs", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      assert Plug.Conn.get_req_header(conn, "x-jx-correlation-id") == [correlation_id]
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "command_id" => "test",
               "execution_protocol" => "jx.runner.v1",
               "jx_action_id" => action.action_id,
               "jx_assignment_id" => assignment.assignment_id,
               "jx_safe_action_kind" => "rerun_devide_command"
             }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        201,
        Jason.encode!(%{
          protocol: "jx.runner.v1",
          assignment: %{
            id: "dev-asgn-runner",
            workspace_id: "ws-devide-runner",
            safe_action_id: "command:test",
            safe_action_version: 1,
            status: "queued",
            action: %{
              id: "command:test",
              kind: "workspace_command",
              command_id: "test",
              argv: ["mix", "test", "--color"],
              requires: ["workspace-command:v1"]
            },
            metadata: %{
              correlation_id: correlation_id,
              jx_assignment_id: assignment.assignment_id,
              jx_action_id: action.action_id,
              jx_safe_action_kind: "rerun_devide_command"
            }
          }
        })
      )
    end)

    assert {:ok, enqueued} =
             DelegatedExecution.enqueue_devide_runner_assignment(assignment.assignment_id,
               client: client,
               now: DateTime.add(now, 1, :second)
             )

    assert enqueued.summary =~ "dev-asgn-runner"

    assert get_in(Jason.decode!(enqueued.metadata), ["devide_runner", "assignment_id"]) ==
             "dev-asgn-runner"

    assert Enum.any?(
             Workspace.operational_timeline("assignment", assignment.assignment_id, limit: 100).events,
             &(&1.kind == "devide_runner.assignment_enqueued" and
                 &1.correlation_id == correlation_id)
           )

    Bypass.expect(bypass, "GET", "/api/runner/v1/assignments/dev-asgn-runner", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(devide_runner_replay(assignment, action, correlation_id))
      )
    end)

    assert {:ok, failed} =
             DelegatedExecution.reconcile_devide_runner_assignment("dev-asgn-runner",
               client: client,
               now: DateTime.add(now, 2, :second)
             )

    assert failed.status == "failed"
    assert failed.summary =~ "failed"

    before_count = Repo.aggregate(OperationalEvent, :count)

    assert {:ok, duplicate} =
             DelegatedExecution.reconcile_devide_runner_assignment("dev-asgn-runner",
               client: client,
               now: DateTime.add(now, 3, :second)
             )

    assert duplicate.status == "failed"
    assert Repo.aggregate(OperationalEvent, :count) == before_count

    timeline = Workspace.operational_timeline("assignment", assignment.assignment_id, limit: 100)
    kinds = Enum.map(timeline.events, & &1.kind)
    assert "devide_runner.report_reconciled" in kinds
    assert "devide_runner.assignment_failed" in kinds

    failed_event = Enum.find(timeline.events, &(&1.kind == "devide_runner.assignment_failed"))
    assert failed_event.correlation_id == correlation_id
    assert failed_event.severity == "warning"
    assert failed_event.payload =~ "assertion failed"
  end

  test "DevIDE runner replay mismatches are rejected and recorded" do
    now = DateTime.utc_now()
    action = planned_action!("ws-replay-mismatch", "apr-replay-mismatch", "test")
    correlation_id = action |> action_payload() |> Map.fetch!("correlation_id")
    assert {:ok, assignment} = DelegatedExecution.create_assignment(action.action_id, now: now)

    replay =
      assignment
      |> devide_runner_replay(action, correlation_id)
      |> put_in([:assignment, :workspace_id], "other-workspace")

    assert {:error, {:replay_mismatch, :workspace_id}} =
             DelegatedExecution.reconcile_devide_runner_replay(replay,
               assignment_id: assignment.assignment_id
             )

    mismatch =
      Workspace.operational_timeline("assignment", assignment.assignment_id, limit: 100).events
      |> Enum.find(&(&1.kind == "devide_runner.replay_mismatch"))

    assert mismatch.severity == "warning"
    assert mismatch.payload =~ "replay_mismatch"
  end

  test "reconciler loop ingests DevIDE runner replay repeatedly without duplicate events" do
    now = DateTime.utc_now()
    action = planned_action!("ws-reconciler", "apr-reconciler", "test")
    correlation_id = action |> action_payload() |> Map.fetch!("correlation_id")
    assert {:ok, assignment} = DelegatedExecution.create_assignment(action.action_id, now: now)

    assignment =
      assignment
      |> Assignment.changeset(%{
        metadata:
          Jason.encode!(%{
            "devide_runner" => %{"assignment_id" => "dev-asgn-runner"},
            "routing" => %{}
          })
      })
      |> Repo.update!()

    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: @token)

    Bypass.expect(bypass, "GET", "/api/runner/v1/assignments/dev-asgn-runner", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(devide_runner_replay(assignment, action, correlation_id))
      )
    end)

    assert [{:ok, %Assignment{status: "failed"}}] =
             RunnerReconciler.run_once(client: client)

    before_count = Repo.aggregate(OperationalEvent, :count)

    assert [{:ok, %Assignment{status: "failed"}}] =
             RunnerReconciler.run_once(client: client)

    assert Repo.aggregate(OperationalEvent, :count) == before_count
  end

  test "runner capability routing constrains selection without authorizing commands" do
    now = DateTime.utc_now()
    action = planned_action!("ws-routed", "apr-routed", "test")

    assert {:ok, assignment} =
             DelegatedExecution.create_assignment(action.action_id,
               now: now,
               runner_requirements: %{
                 host: "host-a",
                 os: "darwin",
                 tools: ["mix"],
                 repo: "example-project",
                 branch_isolation: "worktree"
               }
             )

    register_capable_runner!("runner-wrong-host", "agent-wrong-host", "ws-routed", now,
      metadata: %{
        os: "darwin",
        tools: ["mix"],
        repo: "example-project",
        branch_isolation: "worktree"
      },
      host_name: "host-b"
    )

    assert {:error, {:runner_host_mismatch, "host-a"}} =
             DelegatedExecution.claim_runner_assignment(
               assignment.assignment_id,
               "runner-wrong-host",
               now: now
             )

    register_capable_runner!("runner-routed", "agent-routed", "ws-routed", now,
      metadata: %{
        os: "darwin",
        tools: ["mix"],
        repo: "example-project",
        branch_isolation: "worktree",
        concurrency_limit: 1
      },
      host_name: "host-a"
    )

    assert {:ok, %{assignment: claimed}} =
             DelegatedExecution.claim_runner_assignment(
               assignment.assignment_id,
               "runner-routed",
               now: now,
               session_id: "rsess-routed"
             )

    assert claimed.status == "claimed"
    assert claimed.safe_action_kind == "rerun_devide_command"

    insert_approval!("apr-routed-second", workspace_id: "ws-routed", command_id: "test")
    assert {:ok, proposed_second} = SafeActions.propose("apr-routed-second")
    second_action = proposed_second.action

    assert {:ok, second} =
             DelegatedExecution.create_assignment(second_action.action_id,
               now: now,
               runner_requirements: %{host: "host-a", os: "darwin", tools: ["mix"]}
             )

    assert {:error, {:runner_concurrency_limit, 1}} =
             DelegatedExecution.claim_runner_assignment(
               second.assignment_id,
               "runner-routed",
               now: now
             )
  end

  test "operational projections rebuild deterministically from append-only events" do
    now = DateTime.utc_now()
    action = planned_action!("ws-projection", "apr-projection", "test")
    assert {:ok, assignment} = DelegatedExecution.create_assignment(action.action_id, now: now)
    register_capable_agent!("agent-projection", "ws-projection", now)

    assert {:ok, _claimed} =
             DelegatedExecution.claim_assignment(assignment.assignment_id, "agent-projection",
               now: now
             )

    assert {:ok, _failed} =
             DelegatedExecution.fail_assignment(
               assignment.assignment_id,
               "agent-projection",
               "projection failure",
               now: now
             )

    rebuilt_one = Workspace.operational_rebuilt_state(limit: 1_000)
    rebuilt_two = Workspace.operational_rebuilt_state(limit: 1_000)
    state_one = rebuilt_one.state
    state_two = rebuilt_two.state

    assert state_one == state_two
    assert state_one.assignments[assignment.assignment_id].status == "failed"
    assert rebuilt_one.queue.failures["action_failed"].count >= 1
    assert map_size(rebuilt_one.queue.runners) >= 0
    assert map_size(rebuilt_one.queue.workspaces) >= 0
  end

  test "operator dashboard exposes event-plane state without adding control authority" do
    now = DateTime.utc_now()
    action = planned_action!("ws-dashboard", "apr-dashboard", "test")
    correlation_id = action |> action_payload() |> Map.fetch!("correlation_id")

    assert {:ok, assignment} =
             DelegatedExecution.create_assignment(action.action_id, now: now, ttl_seconds: 60)

    register_capable_runner!("runner-dashboard", "agent-runner-dashboard", "ws-dashboard", now,
      ttl_seconds: 2
    )

    assert {:ok, %{assignment: claimed, session: session}} =
             DelegatedExecution.claim_runner_assignment(
               assignment.assignment_id,
               "runner-dashboard",
               session_id: "rsess-dashboard",
               now: now,
               ttl_seconds: 60
             )

    assert {:ok, _stale_lease} =
             JX.OperationalLeases.acquire("workspace", "ws-dashboard", "operator-dashboard",
               now: now,
               ttl_seconds: 1,
               metadata: %{workspace_id: "ws-dashboard"}
             )

    assert {:ok, failed} =
             claimed
             |> devide_runner_replay(action, correlation_id)
             |> DelegatedExecution.reconcile_devide_runner_replay(
               assignment_id: claimed.assignment_id,
               now: DateTime.add(now, 1, :second)
             )

    assert failed.status == "failed"

    assert {:ok, _future_event} =
             JX.OperationalEvents.record(%{
               source: "test",
               kind: "future.dashboard.event",
               entity_type: "workspace",
               entity_id: "ws-dashboard",
               workspace_id: "ws-dashboard",
               correlation_id: "corr-dashboard-future",
               severity: "notice",
               summary: "future event tolerated by dashboard projections",
               payload: %{future: true}
             })

    later = DateTime.add(now, 3, :second)
    dashboard = Workspace.operator_dashboard(now: later, limit: 100, event_limit: 100)

    assert Enum.any?(
             dashboard.assignments.failed,
             &(&1.assignment_id == assignment.assignment_id)
           )

    assert Enum.any?(dashboard.leases.stale, &(&1.resource_id == "ws-dashboard"))
    assert Enum.any?(dashboard.recent_events, &(&1.kind == "future.dashboard.event"))
    assert dashboard.reconciliation.failed >= 1

    assert Enum.any?(
             dashboard.runner_fleet.sessions,
             &(&1.session_id == session.session_id and &1.status in ["expired", "stale", "failed"])
           )

    rebuilt_one =
      Workspace.operator_dashboard(now: later, limit: 100, event_limit: 100).projections

    rebuilt_two =
      Workspace.operator_dashboard(now: later, limit: 100, event_limit: 100).projections

    assert rebuilt_one == rebuilt_two

    workspace = Workspace.operator_dashboard_workspace("ws-dashboard", event_limit: 100)
    assert Enum.any?(workspace.assignments, &(&1.assignment_id == assignment.assignment_id))
    assert Enum.any?(workspace.timeline.events, &(&1.kind == "future.dashboard.event"))

    assert {:ok, runner} =
             Workspace.operator_dashboard_runner("runner-dashboard", event_limit: 100)

    assert Enum.any?(runner.sessions, &(&1.session_id == session.session_id))
    assert Enum.any?(runner.reports, &(&1.kind == "runner_session.claimed"))

    assert {:ok, assignment_view} =
             Workspace.operator_dashboard_assignment(assignment.assignment_id, event_limit: 100)

    assert assignment_view.replay.failure_class in ["action_failed", nil]
    assert Enum.any?(assignment_view.runner_reports, &(&1.kind == "runner_session.claimed"))

    assert Enum.any?(
             assignment_view.timeline.events,
             &(&1.kind == "devide_runner.assignment_failed")
           )

    assert {:ok, action_view} =
             Workspace.operator_dashboard_action(action.action_id, event_limit: 100)

    assert Enum.any?(action_view.assignments, &(&1.assignment_id == assignment.assignment_id))
    assert action_view.reconciliation.failed >= 1

    dashboard_output =
      capture_io(fn ->
        assert :ok = CLI.run(["dashboard", "--events", "100", "-n", "100"])
      end)

    assert dashboard_output =~ "operator dashboard"
    assert dashboard_output =~ "reconciliation"
    assert dashboard_output =~ "failed work"

    workspace_output =
      capture_io(fn ->
        assert :ok = CLI.run(["dashboard", "workspace", "ws-dashboard", "--events", "100"])
      end)

    assert workspace_output =~ "workspace dashboard ws-dashboard"
    assert workspace_output =~ assignment.assignment_id

    runner_output =
      capture_io(fn ->
        assert :ok = CLI.run(["dashboard", "runner", "runner-dashboard", "--events", "100"])
      end)

    assert runner_output =~ "runner dashboard runner-dashboard"
    assert runner_output =~ session.session_id

    assignment_output =
      capture_io(fn ->
        assert :ok =
                 CLI.run(["dashboard", "assignment", assignment.assignment_id, "--events", "100"])
      end)

    assert assignment_output =~ "assignment dashboard #{assignment.assignment_id}"
    assert assignment_output =~ "replay"

    action_output =
      capture_io(fn ->
        assert :ok = CLI.run(["dashboard", "action", action.action_id, "--events", "100"])
      end)

    assert action_output =~ "safe-action dashboard #{action.action_id}"

    help_output =
      capture_io(fn ->
        assert :ok = CLI.run(["help", "dashboard"])
      end)

    assert help_output =~ "visibility"
    assert help_output =~ "jx dashboard assignment"
  end

  test "stale runner sessions expire assignments and allow safe reassignment" do
    now = DateTime.utc_now()
    action = planned_action!("ws-stale-runner", "apr-stale-runner", "test")

    assert {:ok, first} =
             DelegatedExecution.create_assignment(action.action_id, now: now, ttl_seconds: 60)

    register_capable_runner!("runner-stale-a", "agent-runner-stale-a", "ws-stale-runner", now,
      ttl_seconds: 2
    )

    assert {:ok, %{assignment: claimed, session: session}} =
             DelegatedExecution.claim_runner_assignment(
               first.assignment_id,
               "runner-stale-a",
               session_id: "rsess-stale",
               now: now,
               ttl_seconds: 60
             )

    later = DateTime.add(now, 3, :second)

    assert [%RunnerSession{session_id: "rsess-stale", status: "expired"}] =
             DelegatedExecution.expire_runner_sessions(now: later)

    assert Repo.get_by!(Assignment, assignment_id: first.assignment_id).status == "expired"
    assert Repo.get_by!(Lease, lease_id: claimed.lease_id).status == "released"

    assert {:ok, replacement} =
             DelegatedExecution.create_assignment(action.action_id, now: later, ttl_seconds: 60)

    refute replacement.assignment_id == first.assignment_id

    register_capable_runner!(
      "runner-stale-b",
      "agent-runner-stale-b",
      "ws-stale-runner",
      later
    )

    assert {:ok, %{assignment: reclaimed}} =
             DelegatedExecution.claim_runner_assignment(
               replacement.assignment_id,
               "runner-stale-b",
               now: later,
               ttl_seconds: 60
             )

    assert reclaimed.status == "claimed"
    assert reclaimed.runner_id == "runner-stale-b"

    assert [
             "runner_session.created",
             "runner_session.claimed",
             "runner_session.expired"
           ] =
             session.session_id
             |> runner_reports_for_session()
             |> Enum.map(& &1.kind)
  end

  test "CLI queue, assignment lists, and timelines compose the operator handoff" do
    action = planned_action!("ws-cli", "apr-cli", "test")

    register_output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "agents",
                   "register",
                   "agent-cli",
                   "--capability",
                   @capability,
                   "--workspace",
                   "ws-cli"
                 ])
      end)

    assert register_output =~ "registered agent-cli"

    create_output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "assignments",
                   "create",
                   action.action_id,
                   "--created-by",
                   "operator-cli"
                 ])
      end)

    assert create_output =~ "created asgn-"
    assignment = Repo.one!(Assignment)

    claim_output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "assignments",
                   "claim",
                   assignment.assignment_id,
                   "--agent",
                   "agent-cli"
                 ])
      end)

    assert claim_output =~ "claimed #{assignment.assignment_id}"

    assignments_output =
      capture_io(fn ->
        assert :ok = CLI.run(["assignments", "ls", "--status", "active"])
      end)

    assert assignments_output =~ assignment.assignment_id
    assert assignments_output =~ "agent-cli"
    assert assignments_output =~ "jx assignments execute #{assignment.assignment_id}"

    queue_output =
      capture_io(fn ->
        assert :ok = CLI.run(["queue", "ls", "--kind", "assignment"])
      end)

    assert queue_output =~ assignment.assignment_id
    assert queue_output =~ "assignment"

    assignment_timeline =
      capture_io(fn ->
        assert :ok = CLI.run(["timeline", "assignment", assignment.assignment_id])
      end)

    assert assignment_timeline =~ "timeline assignment #{assignment.assignment_id}"
    assert assignment_timeline =~ "assignment.claimed"

    agent_timeline =
      capture_io(fn ->
        assert :ok = CLI.run(["timeline", "agent", "agent-cli"])
      end)

    assert agent_timeline =~ "timeline agent agent-cli"
    assert agent_timeline =~ "agent.registered"
    assert agent_timeline =~ "assignment.claimed"

    rebuilt = Workspace.operational_rebuilt_state(limit: 1_000)
    assert rebuilt.state.assignments[assignment.assignment_id].status == "claimed"
    assert get_in(rebuilt.state.timelines, ["assignment:#{assignment.assignment_id}"])
    assert get_in(rebuilt.state.timelines, ["agent:agent-cli"])

    check_output =
      capture_io(fn ->
        assert :ok = CLI.run(["events", "check"])
      end)

    assert check_output =~ "assignments"
    assert check_output =~ "agents"

    assert Repo.aggregate(OperationalEvent, :count) > 0
  end

  test "CLI runner and session commands compose without hidden execution" do
    action = planned_action!("ws-cli-runner", "apr-cli-runner", "test")

    register_output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "runners",
                   "register",
                   "runner-cli",
                   "--agent",
                   "agent-cli-runner",
                   "--host",
                   "host-cli",
                   "--capability",
                   @capability,
                   "--workspace",
                   "ws-cli-runner",
                   "--tmux-server",
                   "jx",
                   "--tmux-session-prefix",
                   "jx-cli"
                 ])
      end)

    assert register_output =~ "registered runner-cli"
    assert register_output =~ "agent: agent-cli-runner"

    create_output =
      capture_io(fn ->
        assert :ok = CLI.run(["assignments", "create", action.action_id])
      end)

    assert create_output =~ "created asgn-"
    assignment = Repo.one!(Assignment)

    claim_output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "assignments",
                   "claim",
                   assignment.assignment_id,
                   "--runner",
                   "runner-cli",
                   "--session",
                   "rsess-cli",
                   "--tmux-session",
                   "jx-cli-owned",
                   "--log-path",
                   "/tmp/jx-cli-owned.log"
                 ])
      end)

    assert claim_output =~ "claimed #{assignment.assignment_id}"
    assert claim_output =~ "runner: runner-cli"
    assert claim_output =~ "session: rsess-cli"

    assignments_output =
      capture_io(fn ->
        assert :ok = CLI.run(["assignments", "ls", "--status", "active"])
      end)

    assert assignments_output =~ "runner-cli"
    assert assignments_output =~ "rsess-cli"

    runners_output =
      capture_io(fn ->
        assert :ok = CLI.run(["runners", "ls", "--status", "all"])
      end)

    assert runners_output =~ "runner-cli"
    assert runners_output =~ "busy"

    sessions_output =
      capture_io(fn ->
        assert :ok = CLI.run(["sessions", "ls", "--status", "active"])
      end)

    assert sessions_output =~ "rsess-cli"
    assert sessions_output =~ "jx-cli-owned"

    show_output =
      capture_io(fn ->
        assert :ok = CLI.run(["sessions", "show", "rsess-cli"])
      end)

    assert show_output =~ "session rsess-cli"
    assert show_output =~ "tmux: jx/jx-cli-owned"

    logs_output =
      capture_io(fn ->
        assert :ok = CLI.run(["sessions", "logs", "rsess-cli", "--lines", "20"])
      end)

    assert logs_output =~ "stored log metadata only; no remote command executed"

    attach_output =
      capture_io(fn ->
        assert :ok = CLI.run(["sessions", "attach", "rsess-cli"])
      end)

    assert attach_output =~ "command: tmux -L jx attach -t jx-cli-owned"
    assert attach_output =~ "jx did not execute tmux"

    queue_output =
      capture_io(fn ->
        assert :ok = CLI.run(["queue", "ls", "--kind", "session"])
      end)

    assert queue_output =~ "rsess-cli"
    assert queue_output =~ "session"

    runner_timeline =
      capture_io(fn ->
        assert :ok = CLI.run(["timeline", "runner", "runner-cli"])
      end)

    assert runner_timeline =~ "timeline runner runner-cli"
    assert runner_timeline =~ "runner_session.claimed"

    session_timeline =
      capture_io(fn ->
        assert :ok = CLI.run(["timeline", "session", "rsess-cli"])
      end)

    assert session_timeline =~ "timeline session rsess-cli"
    assert session_timeline =~ "runner_session.attach"
  end

  defp planned_action!(workspace_id, approval_id, command_id) do
    insert_snapshot!(workspace_id, db_isolation: "local")
    insert_approval!(approval_id, workspace_id: workspace_id, command_id: command_id)
    assert {:ok, proposed} = SafeActions.propose(approval_id)
    proposed.action
  end

  defp register_capable_agent!(agent_id, workspace_id, now) do
    assert {:ok, agent} =
             DelegatedExecution.register_agent(%{
               agent_id: agent_id,
               capabilities: [@capability],
               workspace_affinity: [workspace_id],
               now: now
             })

    agent
  end

  defp register_capable_runner!(runner_id, agent_id, workspace_id, now, opts \\ []) do
    assert {:ok, runner} =
             DelegatedExecution.register_runner(%{
               runner_id: runner_id,
               agent_id: agent_id,
               host_name: Keyword.get(opts, :host_name, ""),
               capabilities: [@capability],
               workspace_affinity: [workspace_id],
               heartbeat_ttl_seconds: Keyword.get(opts, :ttl_seconds, 120),
               metadata: Keyword.get(opts, :metadata, %{}),
               now: now
             })

    runner
  end

  defp insert_snapshot!(workspace_id, opts) do
    db_isolation = Keyword.fetch!(opts, :db_isolation)
    now = DateTime.utc_now()

    snapshot = %{
      id: workspace_id,
      name: "Workspace #{workspace_id}",
      status: "blocked",
      lifecycle_status: "running",
      mode: "review",
      db_isolation: db_isolation,
      active_run: nil,
      latest_runs: [%{command_id: "test", status: "failed"}],
      proposal_risks: [],
      recent_blocks: [],
      attention_flags: ["active_run:failed"]
    }

    %WorkspaceSnapshot{}
    |> WorkspaceSnapshot.changeset(%{
      workspace_id: workspace_id,
      name: "Workspace #{workspace_id}",
      lifecycle_status: "running",
      status: "blocked",
      mode: "review",
      db_isolation: db_isolation,
      attention_flags: Jason.encode!(["active_run:failed"]),
      snapshot: Jason.encode!(snapshot),
      fingerprint: "fp-#{workspace_id}-#{System.unique_integer([:positive])}",
      source_url: "http://devide.local",
      last_observed_at: now,
      last_changed_at: now
    })
    |> Repo.insert!()
  end

  defp insert_approval!(approval_id, opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    command_id = Keyword.fetch!(opts, :command_id)

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
  end

  defp action_payload(%OrchestrationAction{} = action), do: Jason.decode!(action.payload)

  defp reports_for_assignment(assignment_id) do
    Report
    |> where([report], report.assignment_id == ^assignment_id)
    |> order_by([report], asc: report.id)
    |> Repo.all()
  end

  defp operational_events_for_assignment(assignment_id) do
    OperationalEvent
    |> where([event], event.entity_type == "assignment" and event.entity_id == ^assignment_id)
    |> order_by([event], asc: event.id)
    |> Repo.all()
  end

  defp runner_reports_for_session(session_id) do
    RunnerReport
    |> where([report], report.session_id == ^session_id)
    |> order_by([report], asc: report.id)
    |> Repo.all()
  end

  defp safe_action_events(action_id) do
    ExecutionEvent
    |> where([event], event.action_id == ^action_id)
    |> order_by([event], asc: event.id)
    |> Repo.all()
  end

  defp run_response(conn, run_id, workspace_id, command_id) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      201,
      Jason.encode!(%{
        id: run_id,
        workspace_id: workspace_id,
        command_id: command_id,
        status: "running"
      })
    )
  end

  defp devide_runner_replay(
         %Assignment{} = assignment,
         %OrchestrationAction{} = action,
         correlation_id
       ) do
    %{
      protocol: "jx.runner.v1",
      assignment: %{
        id: "dev-asgn-runner",
        workspace_id: assignment.workspace_id,
        safe_action_id: "command:test",
        safe_action_version: 1,
        status: "failed",
        claimed_by: "real-runner",
        completed_at: "2026-05-10T01:00:00Z",
        failure_reason: "assertion failed",
        evidence: %{"exit_code" => 2, "output_sha256" => "sha256-failed"},
        metadata: %{
          correlation_id: correlation_id,
          jx_assignment_id: assignment.assignment_id,
          jx_action_id: action.action_id,
          jx_safe_action_kind: "rerun_devide_command"
        }
      },
      reports: [
        %{
          id: "dev-report-1",
          client_report_id: "runner-progress-1",
          assignment_id: "dev-asgn-runner",
          runner_id: "real-runner",
          position: 1,
          event: "progress",
          message: "mix test started",
          evidence: %{},
          observed_at: "2026-05-10T00:59:00Z"
        },
        %{
          id: "dev-report-2",
          client_report_id: "runner-terminal-1",
          assignment_id: "dev-asgn-runner",
          runner_id: "real-runner",
          position: 2,
          event: "failed",
          message: "assertion failed",
          evidence: %{"exit_code" => 2, "output_sha256" => "sha256-failed"},
          observed_at: "2026-05-10T01:00:00Z"
        }
      ]
    }
  end

  defp cleanup_state do
    Repo.delete_all(RunnerReport)
    Repo.delete_all(RunnerSession)
    Repo.delete_all(Runner)
    Repo.delete_all(Report)
    Repo.delete_all(Assignment)
    Repo.delete_all(Agent)
    Repo.delete_all(OperationalEvent)
    Repo.delete_all(Lease)
    Repo.delete_all(ExecutionEvent)
    Repo.delete_all(OperationExecution)
    Repo.delete_all(OrchestrationAction)
    Repo.delete_all(Approval)
    Repo.delete_all(Notification)
    Repo.delete_all(MonitorEvent)
    Repo.delete_all(WorkspaceSnapshot)
  end
end
