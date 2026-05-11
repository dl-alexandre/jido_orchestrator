defmodule JX.JidoTools do
  @moduledoc """
  Boundary for Jido tool integration.

  The domain API stays in `JX.Workspace`. Jido actions and agents
  delegate there so runtime orchestration cannot bypass existing policy checks.
  """

  alias JX.Workspace

  @actions [
    JX.Jido.Actions.AcknowledgeMonitorEvents,
    JX.Jido.Actions.AddCiWatch,
    JX.Jido.Actions.AddWakeTrigger,
    JX.Jido.Actions.ApplyCallHandoff,
    JX.Jido.Actions.CallBrief,
    JX.Jido.Actions.CallHandoffs,
    JX.Jido.Actions.CaptureSession,
    JX.Jido.Actions.CloseCallHandoff,
    JX.Jido.Actions.CiDigest,
    JX.Jido.Actions.CiWatches,
    JX.Jido.Actions.CreateDelegation,
    JX.Jido.Actions.DelegationBrief,
    JX.Jido.Actions.DelegationEvidence,
    JX.Jido.Actions.DelegationPreflight,
    JX.Jido.Actions.DelegationReview,
    JX.Jido.Actions.DelegationReviewDecision,
    JX.Jido.Actions.DelegationReviews,
    JX.Jido.Actions.DelegationTiming,
    JX.Jido.Actions.Delegations,
    JX.Jido.Actions.DoctorHost,
    JX.Jido.Actions.HandleMonitorEvent,
    JX.Jido.Actions.HandleMonitorScan,
    JX.Jido.Actions.MarkSession,
    JX.Jido.Actions.MonitorEventStatus,
    JX.Jido.Actions.MonitorEvents,
    JX.Jido.Actions.MonitorScan,
    JX.Jido.Actions.MonitorUnreadEvents,
    JX.Jido.Actions.Notifications,
    JX.Jido.Actions.ObserveSessions,
    JX.Jido.Actions.OrchestrateStep,
    JX.Jido.Actions.OrchestrationActions,
    JX.Jido.Actions.OrchestratorHealth,
    JX.Jido.Actions.OrchestratorHeartbeats,
    JX.Jido.Actions.PolicyOverview,
    JX.Jido.Actions.PortfolioSummary,
    JX.Jido.Actions.ProbeRemoteSessions,
    JX.Jido.Actions.ProjectBrief,
    JX.Jido.Actions.RefreshOrchestrator,
    JX.Jido.Actions.RecordCallHandoff,
    JX.Jido.Actions.RecoveryPlan,
    JX.Jido.Actions.ResumeAdoptSession,
    JX.Jido.Actions.ReviewCiWatch,
    JX.Jido.Actions.RunDueWakeTriggers,
    JX.Jido.Actions.SendSession,
    JX.Jido.Actions.SessionDossiers,
    JX.Jido.Actions.SessionProfiles,
    JX.Jido.Actions.SessionQueues,
    JX.Jido.Actions.SessionReconciliation,
    JX.Jido.Actions.SessionWatches,
    JX.Jido.Actions.SessionSummary,
    JX.Jido.Actions.StreamAdoptSession,
    JX.Jido.Actions.Wake,
    JX.Jido.Actions.WakeTriggers,
    JX.Jido.Actions.WorkBoard
  ]

  def actions, do: @actions

  def run_action(action, params \\ %{}, opts \\ []) do
    context = Keyword.get(opts, :context, %{})

    exec_opts =
      opts
      |> Keyword.drop([:context])
      |> Keyword.put_new(:jido, JX.Jido)

    Jido.Exec.run(action, params, context, exec_opts)
  end

  defdelegate list_sessions(opts \\ []), to: Workspace
  defdelegate snapshot_sessions(opts \\ []), to: Workspace
  defdelegate observe_sessions(opts \\ []), to: Workspace
  defdelegate list_session_observations(opts \\ []), to: Workspace
  defdelegate list_session_changes(opts \\ []), to: Workspace
  defdelegate list_stale_session_observations(opts \\ []), to: Workspace
  defdelegate list_operation_executions(opts \\ []), to: Workspace
  defdelegate list_orchestration_actions(opts \\ []), to: Workspace
  defdelegate orchestrator_health(opts \\ []), to: Workspace
  defdelegate list_orchestrator_heartbeats(opts \\ []), to: Workspace
  defdelegate list_monitor_events(opts \\ []), to: Workspace
  defdelegate list_notifications(opts \\ []), to: Workspace
  defdelegate call_brief(opts \\ []), to: Workspace
  defdelegate create_delegation(attrs), to: Workspace
  defdelegate list_delegations(opts \\ []), to: Workspace
  defdelegate delegation_brief(delegation_id), to: Workspace
  defdelegate delegation_preflight(delegation_id), to: Workspace
  defdelegate delegation_review(delegation_id), to: Workspace
  defdelegate delegation_reviews(opts \\ []), to: Workspace
  defdelegate delegation_timing(opts \\ []), to: Workspace
  defdelegate decide_delegation_review(delegation_id, decision, attrs \\ []), to: Workspace
  defdelegate add_delegation_evidence(delegation_id, attrs), to: Workspace
  defdelegate create_call_handoff(attrs, opts \\ []), to: Workspace
  defdelegate list_call_handoffs(opts \\ []), to: Workspace
  defdelegate close_call_handoff(handoff_id, summary \\ ""), to: Workspace
  defdelegate apply_call_handoff(handoff_id, attrs \\ ""), to: Workspace
  defdelegate policy_overview(), to: Workspace
  defdelegate unread_monitor_events(opts \\ []), to: Workspace
  defdelegate acknowledge_monitor_events(opts \\ []), to: Workspace
  defdelegate monitor_event_status(opts \\ []), to: Workspace
  defdelegate list_session_controls(opts \\ []), to: Workspace
  defdelegate set_session_control(ref, mode, opts \\ []), to: Workspace
  defdelegate clear_session_control(ref), to: Workspace
  defdelegate list_remote_session_observations(opts \\ []), to: Workspace
  defdelegate portfolio_summary(opts \\ []), to: Workspace
  defdelegate project_brief(project_name, opts \\ []), to: Workspace
  defdelegate ci_digest(repo, pr_number, opts \\ []), to: Workspace
  defdelegate list_ci_watches(opts \\ []), to: Workspace
  defdelegate add_ci_watch(attrs), to: Workspace
  defdelegate review_ci_watch(watch_id, opts \\ []), to: Workspace
  defdelegate cancel_ci_watch(watch_id, summary), to: Workspace
  defdelegate wake(attrs), to: Workspace
  defdelegate add_wake_trigger(attrs), to: Workspace
  defdelegate list_wake_triggers(opts \\ []), to: Workspace
  defdelegate run_due_wake_triggers(opts \\ []), to: Workspace
  defdelegate cancel_wake_trigger(trigger_id), to: Workspace
  defdelegate session_summary(opts \\ []), to: Workspace
  defdelegate session_dossiers(opts \\ []), to: Workspace
  defdelegate session_profiles(opts \\ []), to: Workspace
  defdelegate session_queues(opts \\ []), to: Workspace
  defdelegate session_reconciliation(opts \\ []), to: Workspace
  defdelegate recovery_plan(opts \\ []), to: Workspace
  defdelegate list_watches(opts \\ []), to: Workspace
  defdelegate add_watch(ref, attrs), to: Workspace
  defdelegate review_watch(watch_id, opts \\ []), to: Workspace
  defdelegate complete_watch(watch_id, summary), to: Workspace
  defdelegate cancel_watch(watch_id, summary), to: Workspace
  defdelegate monitor_scan(opts \\ []), to: Workspace
  defdelegate orchestrate(opts \\ []), to: Workspace
  defdelegate operate(opts \\ []), to: Workspace
  defdelegate work_board(opts \\ []), to: Workspace
  defdelegate remote_session_candidates(opts \\ []), to: Workspace
  defdelegate probe_remote_sessions(opts \\ []), to: Workspace
  defdelegate broadcast_sessions(message, opts \\ []), to: Workspace
  defdelegate send_session(ref, message, opts \\ []), to: Workspace
  defdelegate capture_session(ref, opts \\ []), to: Workspace
  defdelegate resume_adopt_session(ref, project_name, opts \\ []), to: Workspace
  defdelegate stream_adopt_session(ref, project_name, opts \\ []), to: Workspace
  defdelegate get_session(ref, opts \\ []), to: Workspace
end
