defmodule JX.RuntimeEnvironmentsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JX.Approvals.Approval
  alias JX.CLI
  alias JX.DelegatedExecution
  alias JX.DelegatedExecution.{Agent, Assignment, Report, Runner, RunnerReport, RunnerSession}
  alias JX.DevIDE.Client
  alias JX.DevIDE.WorkspaceSnapshot
  alias JX.Directives.Directive
  alias JX.MonitorEvents.Event, as: MonitorEvent
  alias JX.Notifications.Notification
  alias JX.OperationExecutions.OperationExecution
  alias JX.OperationalEvents.Event, as: OperationalEvent
  alias JX.OperationalLeases.Lease
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Projects.Project
  alias JX.Repo
  alias JX.RuntimeEnvironments
  alias JX.RuntimeEnvironments.Environment
  alias JX.SafeActions
  alias JX.SafeActions.ExecutionEvent
  alias JX.Tasks.Task
  alias JX.Workspace

  @capability "safe_action:rerun_devide_command"
  @token "runtime-token"

  setup do
    cleanup_state()
    :ok
  end

  test "runtime provisioning records lifecycle evidence and routes approved work without executable authority" do
    now = DateTime.utc_now()

    {:ok, _host} =
      Workspace.add_host(%{
        name: "host-runtime",
        transport: "ssh",
        ssh_target: "dev@example.test",
        workspace_path: "/srv/jx"
      })

    {:ok, _project} =
      Workspace.add_project(%{
        name: "saysure",
        host_name: "host-runtime",
        repo_path: "/srv/repos/saysure"
      })

    action = planned_action!("ws-runtime", "apr-runtime", "test")

    provision_output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "runtimes",
                   "provision",
                   action.action_id,
                   "--project",
                   "saysure",
                   "--host",
                   "host-runtime",
                   "--runner",
                   "runner-runtime",
                   "--tool",
                   "mix",
                   "--os",
                   "darwin"
                 ])
      end)

    assert provision_output =~ "provisioned rt-"
    assert_receive {:ssh_script, provision_script}
    assert provision_script =~ "git -C \"$repo\" worktree add -B \"$branch\" \"$runtime\""
    refute provision_script =~ "argv"
    refute provision_script =~ "command_id"

    runtime = Repo.one!(Environment)
    assert runtime.status == "ready"
    assert runtime.runner_id == "runner-runtime"
    assert runtime.worktree_path =~ "/srv/jx/projects/saysure/runtimes/"

    assert {:ok, _runner} =
             DelegatedExecution.register_runner(%{
               runner_id: "runner-runtime",
               agent_id: "agent-runtime",
               host_name: "host-runtime",
               capabilities: [@capability],
               workspace_affinity: ["ws-runtime"],
               metadata: %{
                 runtime_id: runtime.runtime_id,
                 runtime_path: runtime.worktree_path,
                 repo: runtime.repo_path,
                 branch_isolation: "worktree",
                 os: "darwin",
                 tools: ["mix"],
                 concurrency_limit: 1
               },
               now: now
             })

    assert {:ok, result} =
             Workspace.assign_runtime_action(runtime.runtime_id, action.action_id,
               runner_id: "runner-runtime",
               now: DateTime.add(now, 1, :second)
             )

    assert result.runtime.status == "assigned"
    assert result.assignment.status == "claimed"

    assignment = Repo.get_by!(Assignment, action_id: action.action_id)
    assert assignment.runner_id == "runner-runtime"

    assert get_in(Jason.decode!(assignment.metadata), ["runtime", "runtime_id"]) ==
             runtime.runtime_id

    assert get_in(Jason.decode!(assignment.metadata), ["routing", "runtime_id"]) ==
             runtime.runtime_id

    assert get_in(Jason.decode!(assignment.metadata), ["routing", "runtime_path"]) ==
             runtime.worktree_path

    rebuilt = Workspace.operational_rebuilt_state(limit: 1_000)
    assert rebuilt.state.runtime_environments[runtime.runtime_id].status == "assigned"
    assert rebuilt.queue.assigned_runtime_environments == 1
    assert get_in(rebuilt.state.timelines, ["runtime:#{runtime.runtime_id}"])

    runtimes_output =
      capture_io(fn ->
        assert :ok = CLI.run(["runtimes", "ls", "--status", "all"])
      end)

    assert runtimes_output =~ runtime.runtime_id
    assert runtimes_output =~ "assigned"

    dashboard = Workspace.operator_dashboard(limit: 100)
    assert dashboard.runtime_environments.assigned == 1

    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: @token)

    Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-runtime/runs", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      assert payload["command_id"] == "test"
      assert payload["execution_protocol"] == "jx.runner.v1"
      assert get_in(payload, ["runner_requirements", "runtime_id"]) == runtime.runtime_id
      assert get_in(payload, ["runner_requirements", "runtime_path"]) == runtime.worktree_path
      refute Map.has_key?(payload, "argv")
      refute Map.has_key?(payload, "shell")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        201,
        Jason.encode!(%{
          protocol: "jx.runner.v1",
          assignment: %{
            id: "dev-runtime-asgn",
            workspace_id: "ws-runtime",
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
              correlation_id: assignment.correlation_id,
              jx_assignment_id: assignment.assignment_id,
              jx_action_id: action.action_id,
              jx_safe_action_kind: "rerun_devide_command",
              routing: %{
                runtime_id: runtime.runtime_id,
                runtime_path: runtime.worktree_path
              }
            }
          }
        })
      )
    end)

    assert {:ok, enqueued} =
             DelegatedExecution.enqueue_devide_runner_assignment(assignment.assignment_id,
               client: client
             )

    assert enqueued.summary =~ "dev-runtime-asgn"
  end

  test "runtime listing expiration and release cover lifecycle filters" do
    now = DateTime.utc_now()

    expired =
      insert_runtime!(
        runtime_id: "rt-expired",
        workspace_id: "ws-expired",
        status: "ready",
        runner_id: "runner-old",
        expires_at: DateTime.add(now, -1, :second)
      )

    assigned =
      insert_runtime!(
        runtime_id: "rt-assigned",
        workspace_id: "ws-live",
        status: "assigned",
        runner_id: "runner-live",
        assignment_id: "asgn-live",
        expires_at: DateTime.add(now, 60, :second)
      )

    failed =
      insert_runtime!(
        runtime_id: "rt-failed",
        workspace_id: "ws-live",
        status: "failed",
        runner_id: "runner-live"
      )

    assert [%Environment{runtime_id: "rt-expired", status: "expired"}] =
             RuntimeEnvironments.expire(now: now)

    assert RuntimeEnvironments.get(nil) == nil
    assert RuntimeEnvironments.get(" rt-assigned ") == assigned

    active_ids =
      RuntimeEnvironments.list(status: "active", now: now)
      |> Enum.map(& &1.runtime_id)

    assert assigned.runtime_id in active_ids
    refute expired.runtime_id in active_ids
    refute failed.runtime_id in active_ids

    assert [%{runtime_id: "rt-assigned", status: "assigned"}] =
             RuntimeEnvironments.list(
               status: "assigned",
               workspace_id: "ws-live",
               runner_id: "runner-live",
               now: now
             )

    assert {:ok, released} = RuntimeEnvironments.release(" rt-assigned ", now: now)
    assert released.status == "released"
    assert released.assignment_id == ""
    assert {:error, :runtime_not_found} = RuntimeEnvironments.release("missing", now: now)
  end

  test "runtime summaries normalize malformed metadata and direct list values" do
    runtime = %Environment{
      runtime_id: "rt-summary",
      workspace_id: "ws-summary",
      action_id: "act-summary",
      assignment_id: "",
      runner_id: "",
      project_name: "saysure",
      host_name: "host-summary",
      repo_path: "/repo",
      worktree_path: "/runtime",
      branch: "jx/runtime/rt-summary",
      status: "ready",
      capabilities: ["runtime-environment:v1", :extra],
      tools: "not-json",
      os: "darwin",
      branch_isolation: "worktree",
      concurrency_limit: 2,
      reusable: true,
      correlation_id: "corr-summary",
      metadata: nil
    }

    assert %{
             capabilities: ["runtime-environment:v1", "extra"],
             tools: [],
             metadata: %{},
             next: "jx runtimes show rt-summary"
           } = RuntimeEnvironments.summary(runtime)

    assert %{
             "host" => "host-summary",
             "repo" => "/repo",
             "runtime_path" => "/runtime",
             "tools" => ["runtime-environment:v1", "extra"]
           } = RuntimeEnvironments.routing_requirements(%{runtime | tools: runtime.capabilities})
  end

  test "runtime provisioning and assignment return validation errors without execution authority" do
    action = planned_action!("ws-runtime-errors", "apr-runtime-errors", "test")

    assert {:error, :project_required} =
             RuntimeEnvironments.provision_for_action(action.action_id)

    assert {:error, :project_not_found} =
             RuntimeEnvironments.provision_for_action(action.action_id, project: "missing")

    action
    |> OrchestrationAction.changeset(%{status: "executed"})
    |> Repo.update!()

    assert {:error, {:action_not_assignable, "executed"}} =
             RuntimeEnvironments.provision_for_action(action.action_id)

    assert {:error, :runtime_not_found} =
             RuntimeEnvironments.assign_action("missing", action.action_id)

    failed_runtime =
      insert_runtime!(
        runtime_id: "rt-not-ready",
        workspace_id: "ws-runtime-errors",
        action_id: action.action_id,
        status: "failed"
      )

    assert {:error, {:runtime_not_ready, "failed"}} =
             RuntimeEnvironments.assign_action(failed_runtime.runtime_id, action.action_id)
  end

  test "runtime provisioning records failed runtimes and reusable assignment without runner claims" do
    now = DateTime.utc_now()

    {:ok, _host} =
      Workspace.add_host(%{
        name: "host-runtime-direct",
        transport: "ssh",
        ssh_target: "dev@example.test",
        workspace_path: "/srv/jx"
      })

    {:ok, _project} =
      Workspace.add_project(%{
        name: "runtime-direct",
        host_name: "host-runtime-direct",
        repo_path: "/srv/repos/runtime-direct"
      })

    failed_action = planned_action!("ws-runtime-direct", "apr-runtime-direct", "test")

    assert {:error, {:provision_failed, :boom, failed_env}} =
             RuntimeEnvironments.provision_for_action(failed_action.action_id,
               project: "runtime-direct",
               host: "host-runtime-direct",
               runtime_id: "rt-provision-failed",
               now: now,
               runner: fn _host, script ->
                 assert script =~ "git -C \"$repo\" worktree add"
                 {:error, :boom}
               end
             )

    assert failed_env.status == "failed"
    assert failed_env.last_error == ":boom"

    assign_action = planned_action!("ws-runtime-reuse", "apr-runtime-reuse", "test")

    reusable =
      insert_runtime!(
        runtime_id: "rt-reusable",
        workspace_id: "ws-runtime-reuse",
        action_id: assign_action.action_id,
        status: "assigned",
        reusable: true,
        runner_id: ""
      )

    assert {:ok, %{runtime: assigned, assignment: assignment}} =
             RuntimeEnvironments.assign_action(reusable.runtime_id, assign_action.action_id,
               now: DateTime.add(now, 1, :second)
             )

    assert assigned.status == "assigned"
    assert assigned.assignment_id == assignment.assignment_id
    assert assignment.runner_id == ""
  end

  defp planned_action!(workspace_id, approval_id, command_id) do
    insert_snapshot!(workspace_id)
    insert_approval!(approval_id, workspace_id: workspace_id, command_id: command_id)
    assert {:ok, proposed} = SafeActions.propose(approval_id)
    proposed.action
  end

  defp insert_runtime!(attrs) do
    defaults = %{
      runtime_id: "rt-#{System.unique_integer([:positive])}",
      workspace_id: "ws-runtime",
      action_id: "act-runtime",
      assignment_id: "",
      runner_id: "",
      project_name: "saysure",
      host_name: "host-runtime",
      repo_path: "/srv/repos/saysure",
      worktree_path: "/srv/jx/projects/saysure/runtimes/rt",
      branch: "jx/runtime/rt",
      status: "ready",
      capabilities: Jason.encode!(["runtime-environment:v1"]),
      tools: Jason.encode!(["mix"]),
      os: "darwin",
      branch_isolation: "worktree",
      concurrency_limit: 1,
      reusable: true,
      correlation_id: "corr-runtime",
      metadata: Jason.encode!(%{"runtime_dir" => "/srv/jx/projects/saysure/.jx/runtimes/rt"}),
      last_error: "",
      expires_at: nil
    }

    %Environment{}
    |> Environment.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp insert_snapshot!(workspace_id) do
    now = DateTime.utc_now()

    snapshot = %{
      id: workspace_id,
      name: "Workspace #{workspace_id}",
      status: "blocked",
      lifecycle_status: "running",
      mode: "review",
      db_isolation: "local",
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
      db_isolation: "local",
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

  defp cleanup_state do
    Repo.delete_all(RunnerReport)
    Repo.delete_all(RunnerSession)
    Repo.delete_all(Runner)
    Repo.delete_all(Report)
    Repo.delete_all(Assignment)
    Repo.delete_all(Agent)
    Repo.delete_all(Environment)
    Repo.delete_all(OperationalEvent)
    Repo.delete_all(Lease)
    Repo.delete_all(ExecutionEvent)
    Repo.delete_all(OperationExecution)
    Repo.delete_all(OrchestrationAction)
    Repo.delete_all(Approval)
    Repo.delete_all(Notification)
    Repo.delete_all(MonitorEvent)
    Repo.delete_all(Directive)
    Repo.delete_all(Task)
    Repo.delete_all(Project)
    Repo.delete_all(JX.Hosts.Host)
  end
end
