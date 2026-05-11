defmodule JX.JidoToolsTest do
  use ExUnit.Case, async: false

  alias JX.Directives.Directive
  alias JX.Hosts.Host
  alias JX.Jido.Actions.AcknowledgeMonitorEvents
  alias JX.Jido.Actions.AddCiWatch
  alias JX.Jido.Actions.AddWakeTrigger
  alias JX.Jido.Actions.ApplyCallHandoff
  alias JX.Jido.Actions.CallBrief
  alias JX.Jido.Actions.CallHandoffs
  alias JX.Jido.Actions.CaptureSession
  alias JX.Jido.Actions.CiDigest
  alias JX.Jido.Actions.CiWatches
  alias JX.Jido.Actions.CloseCallHandoff
  alias JX.Jido.Actions.CreateDelegation
  alias JX.Jido.Actions.DelegationBrief
  alias JX.Jido.Actions.DelegationEvidence
  alias JX.Jido.Actions.DelegationPreflight
  alias JX.Jido.Actions.DelegationReview
  alias JX.Jido.Actions.DelegationReviewDecision
  alias JX.Jido.Actions.DelegationReviews
  alias JX.Jido.Actions.DelegationTiming
  alias JX.Jido.Actions.Delegations, as: DelegationsAction
  alias JX.Jido.Actions.DoctorHost
  alias JX.Jido.Actions.HandleMonitorEvent
  alias JX.Jido.Actions.HandleMonitorScan
  alias JX.Jido.Actions.MarkSession
  alias JX.Jido.Actions.MonitorEventStatus
  alias JX.Jido.Actions.RefreshOrchestrator
  alias JX.Jido.Actions.MonitorEvents
  alias JX.Jido.Actions.MonitorScan
  alias JX.Jido.Actions.MonitorUnreadEvents
  alias JX.Jido.Actions.Notifications
  alias JX.Jido.Actions.ObserveSessions
  alias JX.Jido.Actions.OrchestrateStep
  alias JX.Jido.Actions.OrchestrationActions
  alias JX.Jido.Actions.OrchestratorHealth
  alias JX.Jido.Actions.OrchestratorHeartbeats
  alias JX.Jido.Actions.PolicyOverview
  alias JX.Jido.Actions.PortfolioSummary
  alias JX.Jido.Actions.ProbeRemoteSessions
  alias JX.Jido.Actions.RecordCallHandoff
  alias JX.Jido.Actions.ProjectBrief
  alias JX.Jido.Actions.RecoveryPlan
  alias JX.Jido.Actions.ResumeAdoptSession
  alias JX.Jido.Actions.ReviewCiWatch
  alias JX.Jido.Actions.RunDueWakeTriggers
  alias JX.Jido.Actions.SendSession
  alias JX.Jido.Actions.SessionDossiers
  alias JX.Jido.Actions.SessionProfiles
  alias JX.Jido.Actions.SessionQueues
  alias JX.Jido.Actions.SessionReconciliation
  alias JX.Jido.Actions.SessionSummary
  alias JX.Jido.Actions.SessionWatches
  alias JX.Jido.Actions.StreamAdoptSession
  alias JX.Jido.Actions.Wake
  alias JX.Jido.Actions.WakeTriggers
  alias JX.Jido.Actions.WorkBoard
  alias JX.JidoTools
  alias JX.CallHandoffs.CallHandoff
  alias JX.Delegations.Delegation
  alias JX.MonitorEvents.Cursor
  alias JX.MonitorEvents.Event
  alias JX.CiWatches.CiWatch
  alias JX.OperationExecutions.OperationExecution
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.OrchestratorRuntime
  alias JX.OrchestratorHeartbeats.Heartbeat
  alias JX.Projects.Project
  alias JX.RemoteSessions.RemoteSessionObservation
  alias JX.Repo
  alias JX.SessionControls.SessionControl
  alias JX.SessionObservations.SessionObservation
  alias JX.SessionProfiles.OperatorProfile
  alias JX.SessionProfiles.SessionProfile
  alias JX.SessionWatches.SessionWatch
  alias JX.Notifications.Notification
  alias JX.Tasks.Task
  alias JX.WakeTriggers.WakeTrigger
  alias JX.Workspace

  setup do
    Repo.delete_all(WakeTrigger)
    Repo.delete_all(SessionObservation)
    Repo.delete_all(Cursor)
    Repo.delete_all(Event)
    Repo.delete_all(Notification)
    Repo.delete_all(CallHandoff)
    Repo.delete_all(Delegation)
    Repo.delete_all(Heartbeat)
    Repo.delete_all(OrchestrationAction)
    Repo.delete_all(OperationExecution)
    Repo.delete_all(CiWatch)
    Repo.delete_all(RemoteSessionObservation)
    Repo.delete_all(SessionProfile)
    Repo.delete_all(OperatorProfile)
    Repo.delete_all(SessionWatch)
    Repo.delete_all(SessionControl)
    Repo.delete_all(Directive)
    Repo.delete_all(Task)
    Repo.delete_all(Project)
    Repo.delete_all(Host)

    {:ok, _host} =
      Workspace.add_host(%{
        name: "build-1",
        ssh_target: "developer@example.test",
        workspace_path: "/srv/agent"
      })

    {:ok, _project} =
      Workspace.add_project(%{
        name: "saysure",
        host_name: "build-1",
        repo_path: "/srv/repos/saysure"
      })

    :ok
  end

  test "jido runtime is supervised by the application" do
    assert is_pid(Process.whereis(JX.Jido.task_supervisor_name()))
    assert is_integer(JX.Jido.agent_count())
    assert is_pid(OrchestratorRuntime.whereis())
    assert {:ok, %{agent_module: JX.OrchestratorAgent}} = OrchestratorRuntime.state()
  end

  test "jido actions are cataloged and executable through JidoTools" do
    assert WorkBoard in JidoTools.actions()
    assert AddCiWatch in JidoTools.actions()
    assert AddWakeTrigger in JidoTools.actions()
    assert ApplyCallHandoff in JidoTools.actions()
    assert CallBrief in JidoTools.actions()
    assert CallHandoffs in JidoTools.actions()
    assert CaptureSession in JidoTools.actions()
    assert CreateDelegation in JidoTools.actions()
    assert DelegationBrief in JidoTools.actions()
    assert DelegationEvidence in JidoTools.actions()
    assert DelegationPreflight in JidoTools.actions()
    assert DelegationReview in JidoTools.actions()
    assert DelegationReviewDecision in JidoTools.actions()
    assert DelegationReviews in JidoTools.actions()
    assert DelegationTiming in JidoTools.actions()
    assert DelegationsAction in JidoTools.actions()
    assert DoctorHost in JidoTools.actions()
    assert HandleMonitorEvent in JidoTools.actions()
    assert HandleMonitorScan in JidoTools.actions()
    assert MarkSession in JidoTools.actions()
    assert RecordCallHandoff in JidoTools.actions()
    assert CloseCallHandoff in JidoTools.actions()
    assert CiDigest in JidoTools.actions()
    assert CiWatches in JidoTools.actions()
    assert MonitorScan in JidoTools.actions()
    assert MonitorEvents in JidoTools.actions()
    assert MonitorUnreadEvents in JidoTools.actions()
    assert Notifications in JidoTools.actions()
    assert AcknowledgeMonitorEvents in JidoTools.actions()
    assert ObserveSessions in JidoTools.actions()
    assert MonitorEventStatus in JidoTools.actions()
    assert OrchestrateStep in JidoTools.actions()
    assert OrchestrationActions in JidoTools.actions()
    assert OrchestratorHealth in JidoTools.actions()
    assert OrchestratorHeartbeats in JidoTools.actions()
    assert PolicyOverview in JidoTools.actions()
    assert PortfolioSummary in JidoTools.actions()
    assert ProbeRemoteSessions in JidoTools.actions()
    assert ProjectBrief in JidoTools.actions()
    assert RecoveryPlan in JidoTools.actions()
    assert ResumeAdoptSession in JidoTools.actions()
    assert ReviewCiWatch in JidoTools.actions()
    assert RunDueWakeTriggers in JidoTools.actions()
    assert SendSession in JidoTools.actions()
    assert SessionDossiers in JidoTools.actions()
    assert SessionProfiles in JidoTools.actions()
    assert SessionQueues in JidoTools.actions()
    assert SessionReconciliation in JidoTools.actions()
    assert SessionSummary in JidoTools.actions()
    assert SessionWatches in JidoTools.actions()
    assert StreamAdoptSession in JidoTools.actions()
    assert Wake in JidoTools.actions()
    assert WakeTriggers in JidoTools.actions()

    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    assert {:ok, %{board: board}} =
             JidoTools.run_action(WorkBoard, %{opts: [host_name: "build-1", type: "agent"]},
               telemetry: :silent
             )

    assert board.total == 1
    assert [%{kind: "codex", allowed_action: "mark-managed"}] = board.items

    assert {:ok, %{dossiers: dossier_report}} =
             JidoTools.run_action(SessionDossiers, %{opts: [host_name: "build-1", type: "agent"]},
               telemetry: :silent
             )

    assert [%{kind: "codex", next_action: %{action: "mark-managed"}}] =
             dossier_report.dossiers

    assert {:ok, %{profiles: profile_report}} =
             JidoTools.run_action(SessionProfiles, %{opts: [host_name: "build-1", type: "agent"]},
               telemetry: :silent
             )

    assert [%{session: %{kind: "codex"}, comparison: %{state: "needs-profile"}}] =
             profile_report.profiles

    assert {:ok, %{queues: queue_report}} =
             JidoTools.run_action(SessionQueues, %{opts: [host_name: "build-1", type: "agent"]},
               telemetry: :silent
             )

    assert [%{action: "mark-managed", total: 1}] = queue_report.queues

    assert {:ok, %{watches: watches}} =
             JidoTools.run_action(SessionWatches, %{opts: []}, telemetry: :silent)

    assert watches == []

    assert {:ok, %{ci_watches: ci_watches}} =
             JidoTools.run_action(CiWatches, %{opts: []}, telemetry: :silent)

    assert ci_watches == []

    assert {:ok, %{wake_triggers: wake_triggers}} =
             JidoTools.run_action(WakeTriggers, %{opts: []}, telemetry: :silent)

    assert wake_triggers == []

    assert {:ok, %{scan: scan}} =
             JidoTools.run_action(MonitorScan, %{opts: [host_name: "build-1", type: "agent"]},
               telemetry: :silent
             )

    assert scan.events_saved > 0

    assert {:ok, %{events: events}} =
             JidoTools.run_action(MonitorEvents, %{opts: [limit: 10]}, telemetry: :silent)

    assert Enum.any?(events, &(&1.kind == "queue.snapshot"))

    assert {:ok, %{unread: unread}} =
             JidoTools.run_action(MonitorUnreadEvents, %{opts: [consumer: "jido-test"]},
               telemetry: :silent
             )

    assert unread.unread_total == scan.events_saved
    assert Enum.any?(unread.events, &(&1.kind == "queue.snapshot"))

    assert {:ok, %{cursor: cursor}} =
             JidoTools.run_action(
               AcknowledgeMonitorEvents,
               %{opts: [consumer: "jido-test"]},
               telemetry: :silent
             )

    assert cursor.last_event_id > 0

    assert {:ok, %{status: status}} =
             JidoTools.run_action(MonitorEventStatus, %{opts: [consumer: "jido-test"]},
               telemetry: :silent
             )

    assert status.caught_up

    assert {:ok, %{orchestration: orchestration}} =
             JidoTools.run_action(
               OrchestrateStep,
               %{opts: [consumer: "jido-orchestrator-test", host_name: "build-1", type: "agent"]},
               telemetry: :silent
             )

    assert orchestration.consumer == "jido-orchestrator-test"
    assert orchestration.execution.mode == "dry-run"

    assert {:ok, %{actions: actions}} =
             JidoTools.run_action(OrchestrationActions, %{opts: []}, telemetry: :silent)

    assert is_list(actions)

    assert {:ok, %{heartbeats: heartbeats}} =
             JidoTools.run_action(OrchestratorHeartbeats, %{opts: []}, telemetry: :silent)

    assert [%Heartbeat{consumer: "jido-orchestrator-test"}] = heartbeats

    assert {:ok, %{health: health}} =
             JidoTools.run_action(OrchestratorHealth, %{opts: []}, telemetry: :silent)

    assert health.status in ["ok", "attention"]
    assert is_list(health.heartbeats)

    assert {:ok, %{notifications: notifications}} =
             JidoTools.run_action(Notifications, %{opts: []}, telemetry: :silent)

    assert is_list(notifications)

    assert {:ok, %{reconciliation: reconciliation}} =
             JidoTools.run_action(
               SessionReconciliation,
               %{opts: [host_name: "build-1", type: "agent"]},
               telemetry: :silent
             )

    assert reconciliation.totals.local_sessions == 1

    assert {:ok, %{brief: brief}} =
             JidoTools.run_action(
               CallBrief,
               %{opts: [host_name: "build-1", type: "agent", observe: false]},
               telemetry: :silent
             )

    assert brief.surface == "call"
    assert brief.context.projects_total >= 1
    assert is_list(brief.agenda)

    assert {:ok, %{handoff: handoff}} =
             JidoTools.run_action(
               RecordCallHandoff,
               %{
                 summary: "Operator approved async continuation.",
                 title: "Test handoff",
                 decisions: ["continue async"],
                 follow_ups: ["report blockers"],
                 opts: [brief: false]
               },
               telemetry: :silent
             )

    assert handoff.status == "open"

    assert {:ok, %{handoffs: [listed_handoff]}} =
             JidoTools.run_action(CallHandoffs, %{opts: [status: "open"]}, telemetry: :silent)

    assert listed_handoff.handoff_id == handoff.handoff_id

    assert {:ok, %{apply: apply_result}} =
             JidoTools.run_action(
               ApplyCallHandoff,
               %{
                 handoff_id: handoff.handoff_id,
                 action: "hold",
                 ref: "jido-handoff-ref",
                 reason: "operator requested a pause"
               },
               telemetry: :silent
             )

    assert apply_result.handoff.status == "applied"
    assert apply_result.action.action == "handoff-hold"

    assert {:ok, %{handoff: closed_handoff}} =
             JidoTools.run_action(
               CloseCallHandoff,
               %{handoff_id: handoff.handoff_id, summary: "closed in test"},
               telemetry: :silent
             )

    assert closed_handoff.status == "closed"

    assert {:ok, %{delegation: delegation}} =
             JidoTools.run_action(
               CreateDelegation,
               %{
                 title: "Worker packet",
                 brief: "Inspect logs and return a focused patch.",
                 project: "saysure",
                 ref: "s-delegate",
                 owner: "foreground",
                 context: ["CI failed"],
                 constraints: ["Do not touch unrelated files"],
                 acceptance: ["Focused tests pass"],
                 verification: ["mix test"],
                 write_paths: ["lib/example.ex"],
                 forbidden_paths: ["lib/unrelated.ex"]
               },
               telemetry: :silent
             )

    assert delegation.status == "queued"

    assert {:ok, %{delegations: [listed_delegation]}} =
             JidoTools.run_action(DelegationsAction, %{opts: [status: "queued"]},
               telemetry: :silent
             )

    assert listed_delegation.delegation_id == delegation.delegation_id

    assert {:ok, %{brief: delegation_brief}} =
             JidoTools.run_action(
               DelegationBrief,
               %{delegation_id: delegation.delegation_id},
               telemetry: :silent
             )

    assert delegation_brief =~ "Inspect logs"
    assert delegation_brief =~ "Write Paths"

    assert {:ok, %{preflight: preflight}} =
             JidoTools.run_action(
               DelegationPreflight,
               %{delegation_id: delegation.delegation_id},
               telemetry: :silent
             )

    assert preflight.status == "ready"

    assert {:ok, %{delegation: evidenced_delegation}} =
             JidoTools.run_action(
               DelegationEvidence,
               %{
                 delegation_id: delegation.delegation_id,
                 command: "mix test",
                 cwd: "/repo",
                 exit_status: 0,
                 kind: "focused",
                 output_excerpt: "tests passed",
                 artifacts: ["test/example_test.exs"],
                 risks: ["full suite not rerun"]
               },
               telemetry: :silent
             )

    assert [%{"status" => "passed", "command" => "mix test"}] =
             Jason.decode!(evidenced_delegation.evidence)

    assert {:ok, %{review: review}} =
             JidoTools.run_action(
               DelegationReview,
               %{delegation_id: delegation.delegation_id},
               telemetry: :silent
             )

    assert review.decision == "hold"
    assert "delegation is not completed" in review.warnings

    assert {:ok, %{reviews: reviews}} =
             JidoTools.run_action(DelegationReviews, %{opts: [integration_status: "pending"]},
               telemetry: :silent
             )

    assert reviews == []

    assert {:ok, completed_delegation} =
             Workspace.complete_delegation(delegation.delegation_id,
               worker_summary: "Worker finished.",
               artifacts: ["lib/example.ex"]
             )

    assert completed_delegation.status == "completed"

    assert {:ok, %{reviews: [pending_review]}} =
             JidoTools.run_action(DelegationReviews, %{opts: [integration_status: "pending"]},
               telemetry: :silent
             )

    assert pending_review.delegation_id == delegation.delegation_id

    assert {:ok, %{delegation: decided_delegation}} =
             JidoTools.run_action(
               DelegationReviewDecision,
               %{
                 delegation_id: delegation.delegation_id,
                 decision: "hold",
                 summary: "Hold for foreground review.",
                 reviewer: "jido-test"
               },
               telemetry: :silent
             )

    assert decided_delegation.integration_status == "held"
    assert decided_delegation.integration_summary == "Hold for foreground review."

    assert {:ok, %{timing: timing}} =
             JidoTools.run_action(DelegationTiming, %{opts: [limit: 10]}, telemetry: :silent)

    assert timing.samples_total == 1
    assert timing.global.samples == 1
    assert timing.pending_reviews.total == 0

    assert {:ok, %{policy: policy}} =
             JidoTools.run_action(PolicyOverview, %{}, telemetry: :silent)

    assert Enum.any?(policy.release_rules, &(&1.action == "push"))
  end

  test "workspace-backed Jido actions execute through the wrapper boundary" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    assert {:ok, %{doctor_report: doctor_report}} =
             JidoTools.run_action(DoctorHost, %{host_name: "build-1", opts: []},
               telemetry: :silent
             )

    assert Enum.map(doctor_report.groups, & &1.name) ==
             ~w(execution workspace tools repositories agents tmux)

    assert {:ok, %{observation_report: observation_report}} =
             JidoTools.run_action(ObserveSessions, %{opts: [host_name: "build-1", type: "agent"]},
               telemetry: :silent
             )

    assert observation_report.saved == 1
    [%{ref: ref}] = observation_report.observations

    assert {:ok, %{control: control}} =
             JidoTools.run_action(
               MarkSession,
               %{ref: ref, mode: "managed", project: "saysure", note: "covered by Jido wrapper"},
               telemetry: :silent
             )

    assert control.mode == "managed"
    assert control.project == "saysure"

    assert {:ok, %{capture: "recent pane output\n"}} =
             JidoTools.run_action(CaptureSession, %{ref: ref, opts: [lines: 20]},
               telemetry: :silent
             )

    assert {:ok, %{directive: directive}} =
             JidoTools.run_action(
               SendSession,
               %{
                 ref: ref,
                 message: "report status and blockers",
                 opts: [enter: false, capture: %{status: "ok"}]
               },
               telemetry: :silent
             )

    assert directive.message == "report status and blockers"
    assert directive.enter == false

    assert {:ok, %{summary: summary}} =
             JidoTools.run_action(SessionSummary, %{opts: [host_name: "build-1", type: "agent"]},
               telemetry: :silent
             )

    assert summary.current.total == 1
    assert summary.registry.projects == 1

    assert {:ok, %{portfolio: portfolio}} =
             JidoTools.run_action(
               PortfolioSummary,
               %{opts: [host_name: "build-1", type: "agent", observe: false]},
               telemetry: :silent
             )

    assert portfolio.totals.registered_projects == 1
    assert portfolio.projects_total >= 1

    assert {:ok, %{project_brief: project_brief}} =
             JidoTools.run_action(ProjectBrief, %{project: "saysure", opts: [observe: false]},
               telemetry: :silent
             )

    assert project_brief.project.name == "saysure"
    assert project_brief.project.registered == true

    assert {:ok, %{ci_watch: watch}} =
             JidoTools.run_action(
               AddCiWatch,
               %{
                 repo: "owner/repo",
                 pr: 42,
                 ref: ref,
                 project: "saysure",
                 head_sha: "abc123",
                 mode: "notify",
                 goal: "wait for checks",
                 success_prompt: "",
                 failure_prompt: ""
               },
               telemetry: :silent
             )

    assert watch.watch_id =~ "ciw-"
    assert watch.ref == ref

    assert {:error, :ci_watch_not_found} =
             ReviewCiWatch.run(%{watch_id: "missing-watch", opts: []}, %{})

    assert {:ok, %{probe_report: probe_report}} =
             JidoTools.run_action(ProbeRemoteSessions, %{opts: [host_name: "build-1"]},
               telemetry: :silent
             )

    assert is_list(probe_report)

    assert {:ok, %{recovery: recovery}} =
             JidoTools.run_action(
               RecoveryPlan,
               %{opts: [host_name: "build-1", type: "agent", observe: false]},
               telemetry: :silent
             )

    assert recovery.status in ["ok", "needs_recovery"]
  end

  test "adoption Jido actions expose plan-only workspace results" do
    Process.put(:fake_ssh_tmux_pane_discovery, "")

    Process.put(
      :fake_ssh_processes,
      """
        PID  PPID STAT TTY      COMMAND
        42      1 S+   pts/7    /usr/local/bin/codex exec
      """
    )

    {:ok, stream_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: stream_ref}] = stream_board.items

    assert {:ok,
            %{
              adoption: %{
                status: "needs-managed-bridge",
                mode: "plan",
                ref: ^stream_ref,
                next_action: %{action: "relaunch-managed"}
              }
            }} =
             StreamAdoptSession.run(
               %{ref: stream_ref, project: "saysure", agent_name: "", relaunch: false},
               %{}
             )

    Process.put(
      :fake_ssh_processes,
      """
        PID  PPID STAT TTY      COMMAND
        200     1 S    ??       /home/user-a/.zed_server/zed run --pid-file /home/user-a/.local/share/zed/server_state/workspace-10/server.pid
        201   200 S    ??       /home/user-a/.local/share/zed/node/cache/_npx/pkg/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64/claude --output-format stream-json --input-format stream-json --resume 00000000-0000-0000-0000-000000000000
      """
    )

    {:ok, resume_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: resume_ref}] = resume_board.items

    assert {:ok,
            %{
              adoption: %{
                status: "resume-available",
                mode: "plan",
                ref: ^resume_ref,
                next_action: %{action: "resume-relaunch"}
              }
            }} =
             ResumeAdoptSession.run(
               %{ref: resume_ref, project: "saysure", agent_name: "", relaunch: false},
               %{}
             )
  end

  test "wake Jido actions create and run scheduled triggers" do
    assert {:ok, %{wake: wake}} =
             JidoTools.run_action(Wake, %{message: "agent requested attention"},
               telemetry: :silent
             )

    assert wake.wake_id =~ "wak-"
    assert Repo.aggregate(Notification, :count) == 1

    past = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.to_iso8601()

    assert {:ok, %{wake_trigger: trigger}} =
             JidoTools.run_action(
               AddWakeTrigger,
               %{
                 message: "scheduled agent wake",
                 next_run_at: past,
                 schedule: "once",
                 severity: "warning"
               },
               telemetry: :silent
             )

    assert trigger.trigger_id =~ "wtr-"

    assert {:ok, %{wake_triggers: report}} =
             JidoTools.run_action(RunDueWakeTriggers, %{limit: 5}, telemetry: :silent)

    assert report.total == 1
    assert [%{status: "emitted", trigger: %{status: "completed"}}] = report.runs
    assert Repo.aggregate(Notification, :count) == 2
  end

  test "orchestrator agent refreshes compact state from workspace observations" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    agent = JX.OrchestratorAgent.new()

    {agent, directives} =
      JX.OrchestratorAgent.cmd(agent, {
        RefreshOrchestrator,
        %{opts: [host_name: "build-1", type: "agent"]}
      })

    assert directives == []
    assert agent.state.status == :observed
    assert agent.state.last_board_total == 1
    assert agent.state.directable_total == 0
    assert agent.state.repo_blocker_total == 0
    assert is_integer(agent.state.planned_decision_total)
    assert is_binary(agent.state.top_priority)
    assert is_binary(agent.state.autonomous_next)
    assert is_binary(agent.state.recovery_status)
  end

  test "orchestrator agent refreshes compact state through supervised AgentServer" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    assert {:ok, agent} =
             OrchestratorRuntime.refresh(host_name: "build-1", type: "agent", observe: false)

    assert agent.state.status == :observed
    assert agent.state.last_board_total == 1
    assert agent.state.managed_total == 0
    assert agent.state.directable_total == 0
  end

  test "jido runtime can supervise an orchestrator agent process" do
    id = "orchestrator-test-#{System.unique_integer([:positive])}"

    assert {:ok, pid} = JX.Jido.start_agent(JX.OrchestratorAgent, id: id)
    assert JX.Jido.whereis(id) == pid

    on_exit(fn -> JX.Jido.stop_agent(id) end)
  end
end
