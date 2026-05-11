defmodule JX.TUI do
  @moduledoc """
  Builds the monitorable terminal UI runbook and live snapshots.

  The snapshot is intentionally a thin read model over existing orchestration
  surfaces. The interactive CLI mode layers explicit, confirmed steering
  actions over this packet so operators can acknowledge, mark, capture, draft,
  or send without losing the compact overview.
  """

  alias JX.NextStep
  alias JX.Workspace

  @default_consumer "tui"
  @default_interval_ms 5_000

  def default_consumer, do: @default_consumer
  def default_interval_ms, do: @default_interval_ms

  @doc """
  Returns the structured terminal UI runbook for the service.
  """
  def plan do
    %{
      generated_at: iso_now(),
      name: "jx TUI runbook",
      objective:
        "Keep durable SSH/tmux-backed agent work observable, policy-gated, and resumable without turning the foreground conversation into a polling loop.",
      monitor_loop: [
        %{
          step: 1,
          name: "Read and steer from the TUI",
          command: "jx tui --no-observe",
          evidence: "headline, health, unread event count, agenda, project focus, steering prompt"
        },
        %{
          step: 2,
          name: "Render a scriptable snapshot",
          command: "jx tui snapshot --observe",
          evidence: "updated session counts, queue changes, latest monitor event"
        },
        %{
          step: 3,
          name: "Let the daemon handle safe work",
          command: "jx orchestrator health --json",
          evidence: "running heartbeat, no stale/error health alerts"
        },
        %{
          step: 4,
          name: "Intervene only on surfaced decisions",
          command: "jx next --json",
          evidence:
            "delegation reviews, blocked policy decisions, ready prompts, CI/watch outcomes"
        },
        %{
          step: 5,
          name: "Audit and close the loop",
          command: "jx actions ls --status executed --json",
          evidence:
            "recorded action outcome, profile/watch/notification state changed as expected"
        }
      ],
      watch_surface: %{
        command: "jx tui watch --interval-ms #{@default_interval_ms}",
        stop: "Ctrl-C",
        safe_by_default: true,
        side_effects:
          "Captures session tails by default; use --no-observe for stored-state only. It never sends input."
      },
      decision_gates: [
        "Send input only through task-owned sessions or managed controls with fresh successful capture.",
        "Treat protected and ignored sessions as inventory, not directable work.",
        "Accept delegation output only after ownership, evidence, and residual risk are recorded.",
        "Treat stale CI watches as historical until current PR head state is reconciled.",
        "Escalate force-pushes, destructive deletes, credential changes, releases, and deploys."
      ],
      primary_surfaces: [
        %{name: "tui", command: "jx tui"},
        %{name: "tui snapshot", command: "jx tui snapshot"},
        %{name: "next action", command: "jx next --json"},
        %{name: "call brief", command: "jx call brief --observe --json"},
        %{name: "portfolio", command: "jx portfolio summary --json"},
        %{name: "daemon health", command: "jx orchestrator health --json"},
        %{
          name: "monitor inbox",
          command: "jx events unread --consumer #{@default_consumer} --json"
        },
        %{name: "audit log", command: "jx actions ls --json"}
      ],
      success_criteria: [
        "A foreground agent can identify the next action from one command.",
        "Daemon freshness and errors are visible without reading logs first.",
        "Unread monitor events and agenda items are visible together.",
        "Project/session counts distinguish running, ready, awaiting, blocked, and parked work.",
        "Every suggested command maps to an existing durable surface."
      ]
    }
  end

  @doc """
  Builds a monitorable terminal UI snapshot.
  """
  def snapshot(opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    consumer = opts |> Keyword.get(:consumer, @default_consumer) |> normalize_consumer()
    stale_after_seconds = Keyword.get(opts, :stale_after_seconds, 120)

    with {:ok, brief} <- Workspace.call_brief(call_brief_opts(opts, limit)) do
      next_step = NextStep.build(brief)

      {:ok,
       %{
         generated_at: iso_now(),
         filters: filters(opts),
         headline: field(brief, :headline, ""),
         next: next_step,
         counts: field(brief, :context, %{}),
         orchestrator: field(brief, :orchestrator, %{}),
         health:
           health_summary(
             Workspace.orchestrator_health(
               stale_after_seconds: stale_after_seconds,
               limit: Keyword.get(opts, :heartbeat_limit, 5)
             )
           ),
         monitor:
           Workspace.monitor_event_status(consumer: consumer)
           |> monitor_status_summary(),
         agenda:
           brief
           |> field(:agenda, [])
           |> List.wrap()
           |> Enum.take(limit),
         projects:
           brief
           |> field(:projects, [])
           |> List.wrap()
           |> Enum.take(limit),
         commands: snapshot_commands(next_step, consumer)
       }}
    end
  end

  defp call_brief_opts(opts, limit) do
    [
      host_name: Keyword.get(opts, :host_name),
      project: Keyword.get(opts, :project),
      all_tmux: Keyword.get(opts, :all_tmux, true),
      all_processes: Keyword.get(opts, :all_processes, false),
      type: Keyword.get(opts, :type),
      ssh_target: Keyword.get(opts, :ssh_target),
      work_state: Keyword.get(opts, :work_state),
      control_mode: Keyword.get(opts, :control_mode),
      observe: Keyword.get(opts, :observe, true),
      lines: Keyword.get(opts, :lines, 80),
      scan_limit: Keyword.get(opts, :scan_limit, max(limit * 5, 100)),
      limit: limit
    ]
  end

  defp filters(opts) do
    %{
      project: Keyword.get(opts, :project, ""),
      host: Keyword.get(opts, :host_name, ""),
      type: Keyword.get(opts, :type, ""),
      ssh_target: Keyword.get(opts, :ssh_target, ""),
      work_state: Keyword.get(opts, :work_state, ""),
      control: Keyword.get(opts, :control_mode, ""),
      observe: Keyword.get(opts, :observe, true)
    }
  end

  defp health_summary(health) do
    %{
      generated_at: iso_time(health.generated_at),
      status: health.status,
      stale_after_seconds: health.stale_after_seconds,
      alerts_total: health.alerts_total,
      heartbeats_total: health.heartbeats_total,
      alerts: Enum.map(health.alerts, &health_alert_summary/1),
      heartbeats: Enum.map(health.heartbeats, &heartbeat_summary/1)
    }
  end

  defp health_alert_summary(alert) do
    %{
      severity: field(alert, :severity, ""),
      reason: field(alert, :reason, ""),
      daemon_key: field(alert, :daemon_key, ""),
      status: field(alert, :status, ""),
      next_wake_at: iso_time(field(alert, :next_wake_at)),
      summary: field(alert, :summary, "")
    }
  end

  defp heartbeat_summary(heartbeat) do
    snapshot = decode_json(field(heartbeat, :scan_snapshot, "{}"))
    guidance = field(snapshot, "guidance", %{})

    %{
      daemon_key: field(heartbeat, :daemon_key, ""),
      consumer: field(heartbeat, :consumer, ""),
      status: field(heartbeat, :status, ""),
      mode: field(heartbeat, :mode, ""),
      last_scan_at: iso_time(field(heartbeat, :last_scan_at)),
      last_decision_at: iso_time(field(heartbeat, :last_decision_at)),
      next_wake_at: iso_time(field(heartbeat, :next_wake_at)),
      last_error: field(heartbeat, :last_error, ""),
      top_priority: field(guidance, "top_priority", ""),
      autonomous_next: field(guidance, "autonomous_next", ""),
      operator_needed_for: field(guidance, "operator_needed_for", []),
      focus_refs: field(guidance, "focus_refs", [])
    }
  end

  defp monitor_status_summary(status) do
    %{
      consumer: status.consumer,
      latest_event_id: status.latest_event_id,
      unread_total: status.unread_total,
      caught_up: status.caught_up,
      cursor: %{
        source: field(status.cursor, :source, ""),
        last_event_id: field(status.cursor, :last_event_id, 0),
        last_seen_at: iso_time(field(status.cursor, :last_seen_at)),
        updated_at: iso_time(field(status.cursor, :updated_at))
      },
      latest_event: maybe_event_summary(status.latest_event)
    }
  end

  defp maybe_event_summary(nil), do: nil

  defp maybe_event_summary(event) do
    %{
      id: field(event, :id, 0),
      kind: field(event, :kind, ""),
      severity: field(event, :severity, ""),
      ref: field(event, :ref, ""),
      project: field(event, :project, ""),
      action: field(event, :action, ""),
      summary: field(event, :summary, ""),
      inserted_at: iso_time(field(event, :inserted_at))
    }
  end

  defp snapshot_commands(next_step, consumer) do
    [
      %{
        label: "next",
        command: field(next_step, :command, "jx next --json"),
        reason: field(next_step, :reason, "")
      },
      %{
        label: "refresh",
        command: "jx tui snapshot --observe",
        reason: "refresh observations and redraw a one-shot TUI snapshot"
      },
      %{
        label: "watch",
        command: "jx tui watch --interval-ms #{@default_interval_ms}",
        reason: "redraw the TUI on an interval"
      },
      %{
        label: "health",
        command: "jx orchestrator health --json",
        reason: "inspect stale/error daemon heartbeat alerts"
      },
      %{
        label: "inbox",
        command: "jx events unread --consumer #{consumer} --json",
        reason: "inspect unacknowledged monitor events for this TUI consumer"
      }
    ]
  end

  defp normalize_consumer(nil), do: @default_consumer

  defp normalize_consumer(consumer) do
    consumer
    |> to_string()
    |> String.trim()
    |> case do
      "" -> @default_consumer
      value -> value
    end
  end

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{}
    end
  end

  defp decode_json(_value), do: %{}

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp field(_value, _key, default), do: default

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp iso_time(nil), do: nil
  defp iso_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso_time(value), do: value
end
