defmodule JX.PublicBoundariesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JX.CiWatches.CiWatch
  alias JX.Directives.Directive
  alias JX.GoogleMeet.{AuthProfile, Session}
  alias JX.Hosts.Host
  alias JX.Repo
  alias JX.SessionControls.SessionControl
  alias JX.SessionProfiles.{OperatorProfile, SessionProfile}
  alias JX.SessionWatches.SessionWatch
  alias JX.Tasks.Task

  setup do
    Repo.delete_all(Session)
    Repo.delete_all(AuthProfile)
    Repo.delete_all(Directive)
    Repo.delete_all(CiWatch)
    Repo.delete_all(SessionWatch)
    Repo.delete_all(SessionControl)
    Repo.delete_all(SessionProfile)
    Repo.delete_all(OperatorProfile)
    Repo.delete_all(Task)
    Repo.delete_all(JX.Projects.Project)
    Repo.delete_all(Host)

    :ok
  end

  test "public JX and JidoTools boundaries delegate into workspace operations" do
    suffix = System.unique_integer([:positive])
    host_name = "boundary-host-#{suffix}"
    project_name = "boundary-project-#{suffix}"
    Process.put(:fake_ssh_tmux_capture, "boundary pane output\n")

    assert {:ok, host} =
             JX.add_host(%{
               name: host_name,
               ssh_target: "developer@example.test",
               workspace_path: "/srv/agent"
             })

    assert {:ok, project} =
             JX.add_project(%{
               name: project_name,
               host_name: host_name,
               repo_path: "/srv/repos/saysure"
             })

    assert {:ok, _report} = JX.doctor_host(host_name, agent_name: "codex")
    assert {:ok, task} = JX.assign_task(project_name, "cover the public API", agent_name: "codex")
    assert Enum.any?(JX.list_statuses(), &(&1.task.task_id == task.task_id))

    assert {:ok, %{sessions: [session | _]}} =
             JX.snapshot_sessions(host_name: host_name, type: "agent")

    session_ref = session.ref

    assert {:ok, _observed} = JX.observe_sessions(host_name: host_name, type: "agent")
    assert {:ok, %{current: _current}} = JX.session_summary(host_name: host_name, type: "agent")
    assert {:ok, %{sessions: _sessions}} = JX.list_sessions(host_name: host_name, type: "agent")
    assert is_list(JX.list_session_observations(limit: 5))
    assert is_list(JX.list_session_changes(limit: 5))
    assert is_list(JX.list_stale_session_observations(seconds: 0, limit: 5))
    assert is_list(JX.list_operation_executions(limit: 5))

    assert {:ok, watch} =
             JX.add_ci_watch(%{
               repo: "owner/repo",
               pr_number: 42,
               ref: task.task_id,
               project: project_name,
               mode: "notify",
               goal: "coverage"
             })

    assert Enum.any?(JX.list_ci_watches(project: project_name), &(&1.watch_id == watch.watch_id))
    assert {:ok, cancelled_watch} = JX.cancel_ci_watch(watch.watch_id, "done")
    assert cancelled_watch.status == "cancelled"

    assert {:ok, handoff} =
             JX.create_call_handoff(%{
               summary: "Apply a public API handoff",
               project: project_name,
               ref: task.task_id
             })

    assert Enum.any?(
             JX.list_call_handoffs(project: project_name),
             &(&1.handoff_id == handoff.handoff_id)
           )

    assert {:ok, applied} = JX.apply_call_handoff(handoff.handoff_id, "covered")
    assert applied.status in ["applied", "closed"]
    assert {:ok, _closed} = JX.close_call_handoff(handoff.handoff_id, "closed")

    assert {:ok, delegation} =
             JX.create_delegation(%{
               title: "Public API delegation",
               brief: "Cover delegate lines",
               project: project_name,
               ref: task.task_id
             })

    assert Enum.any?(
             JX.list_delegations(project: project_name),
             &(&1.delegation_id == delegation.delegation_id)
           )

    assert {:ok, brief} = JX.delegation_brief(delegation.delegation_id)
    assert brief =~ "Public API delegation"
    assert {:ok, _preflight} = JX.delegation_preflight(delegation.delegation_id)
    assert {:ok, _review} = JX.delegation_review(delegation.delegation_id)
    assert is_list(JX.delegation_reviews(project: project_name))
    assert %{samples_total: _count} = JX.delegation_timing(project: project_name)

    assert {:ok, control} = JX.set_session_control(session_ref, "managed", note: "covered")
    assert Enum.any?(JX.list_session_controls(), &(&1.id == control.id))
    assert {:ok, _cleared} = JX.clear_session_control(session_ref)

    assert {:ok, _profile} =
             JX.set_session_profile(session_ref, %{
               summary: "Boundary profile",
               objective: "Cover JX delegates",
               next_prompt: "continue",
               prompt_status: "ready"
             })

    assert %{source: "default"} = JX.operator_profile()
    assert {:ok, operator} = JX.set_operator_profile(%{name: "Boundary Operator"})
    assert operator.name == "Boundary Operator"
    assert {:ok, %{items: _items}} = JX.work_board(host_name: host_name, type: "agent")

    assert {:ok, %{recommendations: _recommendations}} =
             JX.operate(host_name: host_name, type: "agent")

    assert {:ok, remote_candidates} = JX.remote_session_candidates()
    assert is_list(remote_candidates)
    assert {:ok, remote_probes} = JX.probe_remote_sessions()
    assert is_list(remote_probes)

    assert {:ok, %{targets: _targets}} =
             JX.broadcast_sessions("stand by", host_name: host_name, dry_run: true)

    assert {:ok, directive} =
             JX.OperatorDirectives.insert_instruction(%{
               target_type: "tmux",
               tmux_server: "default",
               session_name: "jx_boundary",
               window: 0,
               pane: 0,
               message: "continue",
               enter: false,
               status: "sent",
               host_id: host.id
             })

    assert [listed_directive] = JX.OperatorDirectives.list_instructions(host_name: host_name)
    assert listed_directive.directive_id == directive.directive_id

    assert JX.JidoTools.actions() |> Enum.member?(JX.Jido.Actions.CiDigest)
    assert {:ok, %{sessions: _sessions}} = JX.JidoTools.list_sessions(host_name: host_name)
    assert {:ok, _snapshot} = JX.JidoTools.snapshot_sessions(host_name: host_name)
    assert {:ok, _observed} = JX.JidoTools.observe_sessions(host_name: host_name)
    assert is_list(JX.JidoTools.list_session_observations(limit: 5))
    assert is_list(JX.JidoTools.list_session_changes(limit: 5))
    assert is_list(JX.JidoTools.list_stale_session_observations(limit: 5))
    assert is_list(JX.JidoTools.list_operation_executions(limit: 5))

    assert {:ok, %{agenda: _agenda}} =
             JX.JidoTools.call_brief(host_name: host_name, observe: false)

    assert {:ok, %{projects: _projects}} =
             JX.JidoTools.portfolio_summary(host_name: host_name, observe: false)

    assert {:ok, %{project: %{name: ^project_name}}} =
             JX.JidoTools.project_brief(project_name, observe: false)

    assert %{safety_tiers: _tiers} = JX.JidoTools.policy_overview()
    assert {:ok, %{current: _current}} = JX.JidoTools.session_summary(host_name: host_name)
    assert {:ok, %{dossiers: _dossiers}} = JX.JidoTools.session_dossiers(host_name: host_name)
    assert {:ok, %{queues: _queues}} = JX.JidoTools.session_queues(host_name: host_name)
    assert {:ok, %{profiles: _profiles}} = JX.JidoTools.session_profiles(host_name: host_name)
    assert {:ok, %{totals: _totals}} = JX.JidoTools.session_reconciliation(host_name: host_name)

    assert {:ok, %{recommendations: _recommendations}} =
             JX.JidoTools.recovery_plan(host_name: host_name)

    assert is_list(JX.JidoTools.list_watches())
    assert {:ok, %{queues: _queues}} = JX.JidoTools.monitor_scan(host_name: host_name)
    assert {:ok, %{decisions: _decisions}} = JX.JidoTools.orchestrate(host_name: host_name)
    assert {:ok, %{items: _items}} = JX.JidoTools.work_board(host_name: host_name)

    assert {:ok, %{recommendations: _recommendations}} =
             JX.JidoTools.operate(host_name: host_name)

    assert {:ok, jido_remote_candidates} = JX.JidoTools.remote_session_candidates()
    assert is_list(jido_remote_candidates)
    assert {:ok, jido_remote_probes} = JX.JidoTools.probe_remote_sessions()
    assert is_list(jido_remote_probes)

    assert {:ok, %{targets: _targets}} =
             JX.JidoTools.broadcast_sessions("stand by", host_name: host_name, dry_run: true)

    assert project.host_id == host.id
  end

  test "CliRuntime prepares dependency runtime files from the Mix test process" do
    runtime_dir = Path.join(System.tmp_dir!(), "jx-runtime-#{System.unique_integer([:positive])}")

    assert :ok =
             JX.CliRuntime.prepare(
               tzdata_dir: Path.join(runtime_dir, "tzdata"),
               tzdata_autoupdate: :disabled
             )

    assert [_file | _] = Path.wildcard(Path.join(runtime_dir, "tzdata/release_ets/*.ets"))
  end

  test "system SSH adapter builds ssh commands and reports command failures" do
    tmp = Path.join(System.tmp_dir!(), "jx-ssh-system-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    ssh_path = Path.join(tmp, "ssh")
    args_log = Path.join(tmp, "args.log")

    File.write!(ssh_path, """
    #!/bin/sh
    printf '%s\\n' "$@" > "$SSH_ARGS_LOG"
    if [ "$SSH_MODE" = "fail" ]; then
      printf 'failed\\n'
      exit 23
    fi
    printf 'ok\\n'
    exit 0
    """)

    File.chmod!(ssh_path, 0o755)

    old_path = System.get_env("PATH")
    System.put_env("PATH", tmp <> ":" <> (old_path || ""))
    System.put_env("SSH_ARGS_LOG", args_log)

    on_exit(fn ->
      if old_path, do: System.put_env("PATH", old_path), else: System.delete_env("PATH")
      System.delete_env("SSH_ARGS_LOG")
      System.delete_env("SSH_MODE")
    end)

    host = %Host{ssh_target: "developer@example.test"}

    assert {:ok, "ok\n"} = JX.SSH.System.run(host, "echo covered")
    assert File.read!(args_log) =~ "developer@example.test"
    assert File.read!(args_log) =~ "sh -lc"

    assert capture_io(fn ->
             assert :ok = JX.SSH.System.stream_log(host, "/tmp/jx.log", lines: 5)
           end) ==
             "ok\n"

    assert capture_io(fn -> assert :ok = JX.SSH.System.attach(host, "jx_session") end) ==
             "ok\n"

    System.put_env("SSH_MODE", "fail")
    assert {:error, {:ssh_failed, 23, "failed\n"}} = JX.SSH.System.run(host, "exit 1")

    assert capture_io(fn ->
             assert {:error, {:logs_failed, 23}} =
                      JX.SSH.System.stream_log(host, "/tmp/jx.log")
           end) == "failed\n"

    assert capture_io(fn ->
             assert {:error, {:attach_failed, 23}} = JX.SSH.System.attach(host, "jx_session")
           end) == "failed\n"
  end
end
