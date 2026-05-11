defmodule JX.OrchestratorAgent do
  @moduledoc """
  Minimal Jido agent that keeps compact orchestration state.

  This agent does not replace the external coding agents. It gives the BEAM
  runtime a supervised, stateful place to summarize what the Workspace API sees.
  """

  @id "jx_orchestrator"
  @refresh_signal_type "jx.orchestrator.refresh"
  @monitor_scan_completed_signal_type "jx.monitor.scan.completed"
  @monitor_scan_failed_signal_type "jx.monitor.scan.failed"
  @monitor_signal_routes Enum.map(
                           JX.MonitorEvents.change_kinds(),
                           &{&1, JX.Jido.Actions.HandleMonitorEvent}
                         )

  use Jido.Agent,
    name: "jx_orchestrator",
    description: "Tracks current managed work, attention, and repository blockers",
    signal_routes:
      [
        {@refresh_signal_type, JX.Jido.Actions.RefreshOrchestrator},
        {@monitor_scan_completed_signal_type, JX.Jido.Actions.HandleMonitorScan},
        {@monitor_scan_failed_signal_type, JX.Jido.Actions.HandleMonitorScan}
      ] ++ @monitor_signal_routes,
    schema: [
      status: [type: :atom, default: :idle],
      last_board_total: [type: :integer, default: 0],
      managed_total: [type: :integer, default: 0],
      directable_total: [type: :integer, default: 0],
      repo_blocker_total: [type: :integer, default: 0],
      attention_total: [type: :integer, default: 0],
      event_total: [type: :integer, default: 0],
      warning_event_total: [type: :integer, default: 0],
      planned_decision_total: [type: :integer, default: 0],
      manual_decision_total: [type: :integer, default: 0],
      gated_decision_total: [type: :integer, default: 0],
      top_priority: [type: :string, default: ""],
      autonomous_next: [type: :string, default: ""],
      operator_needed_total: [type: :integer, default: 0],
      focus_refs: [type: {:list, :string}, default: []],
      recovery_status: [type: :string, default: ""],
      recovery_total: [type: :integer, default: 0],
      last_event_id: [type: :string, default: ""],
      last_event_type: [type: :string, default: ""],
      last_event_ref: [type: :string, default: ""],
      last_event_project: [type: :string, default: ""],
      last_event_summary: [type: :string, default: ""],
      scan_total: [type: :integer, default: 0],
      last_scan_status: [type: :string, default: ""],
      last_scan_at: [type: :string, default: ""],
      last_scan_sessions_total: [type: :integer, default: 0],
      last_scan_events_saved: [type: :integer, default: 0],
      last_scan_errors_total: [type: :integer, default: 0],
      last_scan_error: [type: :string, default: ""],
      last_error: [type: :string, default: ""]
    ]

  def id, do: @id

  def refresh_signal_type, do: @refresh_signal_type

  def refresh_signal(opts \\ []) do
    Jido.Signal.new!(@refresh_signal_type, %{opts: opts},
      source: "/jx/orchestrator",
      subject: @id
    )
  end
end
