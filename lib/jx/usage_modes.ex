defmodule JX.UsageModes do
  @moduledoc """
  Catalog of operational modes for running jx.

  The CLI has many focused commands. This module keeps the higher-level
  operator modes in one place so human operators and agents can choose the
  right entrypoint before touching live sessions.
  """

  @modes [
    %{
      id: "tui",
      title: "Terminal UI",
      intent: "Read the live portfolio, queues, handoffs, and policy state before acting.",
      best_for: [
        "starting or resuming a primary agent turn",
        "briefing a human operator",
        "checking whether background orchestration needs help"
      ],
      safety: "read-only except explicit observation capture",
      commands: [
        "jx tui",
        "jx tui snapshot --no-observe",
        "jx tui watch --interval-ms 5000",
        "jx tui plan"
      ]
    },
    %{
      id: "daemon",
      title: "Detached Daemon",
      intent: "Keep scanning, recording events, and executing policy-allowed actions in tmux.",
      best_for: [
        "agent-led background monitoring",
        "long-running portfolios",
        "keeping the foreground conversation available for decisions"
      ],
      safety: "gated by monitor events, action audit records, and operation policy",
      commands: [
        "jx orchestrator start --dry-run --replace",
        "jx orchestrator status",
        "jx orchestrator heartbeats --json",
        "jx orchestrator logs -n 80"
      ]
    },
    %{
      id: "dry-run",
      title: "Dry-Run Planning",
      intent: "Plan or scan orchestration work without sending prompts or mutating live panes.",
      best_for: [
        "checking what the daemon would do",
        "debugging recommendations",
        "reviewing action safety before enabling execution"
      ],
      safety: "no live session sends; recommendations and events are inspectable first",
      commands: [
        "jx monitor scan --json",
        "jx orchestrate step --auto-plan --json",
        "jx operate --observe --json"
      ]
    },
    %{
      id: "execute",
      title: "Gated Execution",
      intent: "Execute safe or explicitly approved orchestration actions.",
      best_for: [
        "sending ready prompts to managed sessions",
        "running safe follow-up observations",
        "advancing queued actions after reviewing policy boundaries"
      ],
      safety:
        "requires managed/task-owned sessions, fresh capture, and explicit --execute/--yes gates",
      commands: [
        "jx orchestrate step --execute --yes --auto-plan",
        "jx operate --execute safe --json",
        "jx actions ls --status executed --json"
      ]
    },
    %{
      id: "session-control",
      title: "Directed Session Control",
      intent: "Mark, profile, capture, and direct a specific tmux or agent session.",
      best_for: [
        "turning a discovered pane into managed work",
        "chambering a next prompt",
        "sending one intentional instruction to one session"
      ],
      safety:
        "protected and ignored sessions cannot be directed; managed sends need fresh capture",
      commands: [
        "jx session mark <ref> --mode managed",
        "jx session profile <ref> --objective <text> --next-prompt <text> --prompt-status ready",
        "jx session capture <ref> -n 80",
        "jx session send <ref> \"<message>\""
      ]
    },
    %{
      id: "watch",
      title: "Durable Watches",
      intent: "React to terminal evidence without polling the foreground conversation.",
      best_for: [
        "waiting for tests or CI-like terminal output",
        "holding a session when blocker text appears",
        "chambering a draft prompt after success evidence"
      ],
      safety:
        "notify is observational, hold blocks for review, prompt drafts but does not blindly send",
      commands: [
        "jx watch add <ref> --goal <text> --success <pattern> --mode notify",
        "jx watch add <ref> --goal <text> --blocker <pattern> --mode hold",
        "jx watch add <ref> --goal <text> --success <pattern> --mode prompt --prompt <text>",
        "jx watch review <watch-id>"
      ]
    },
    %{
      id: "wake",
      title: "External Wake",
      intent:
        "Let scripts, scheduled checks, or operators place work into the orchestration inbox.",
      best_for: [
        "one-shot reminders without another scheduler",
        "recurring project or CI review nudges",
        "future webhook adapters that should not bypass monitor events"
      ],
      safety:
        "wake triggers only create monitor events and notifications; live session action stays gated",
      commands: [
        "jx wake --message <text> --project <name>",
        "jx wake add --message <text> --in 30m",
        "jx wake add --message <text> --every 15m",
        "jx wake ls --status active"
      ]
    },
    %{
      id: "delegation",
      title: "Delegation Review",
      intent: "Run bounded worker packets and require evidence before integration decisions.",
      best_for: [
        "parallel implementation with declared ownership",
        "reviewing completed worker output",
        "recording accept, revise, reject, or hold decisions"
      ],
      safety: "delegations expose write paths, evidence, lint checks, and integration status",
      commands: [
        "jx delegate create --title <text> --brief <text> --write <path>",
        "jx delegate lint <delegation-id> --json",
        "jx delegate evidence <delegation-id> --command <cmd> --cwd <path> --exit <code>",
        "jx delegate decide <delegation-id> --decision accept|revise|reject|hold"
      ]
    },
    %{
      id: "meet",
      title: "Meeting Participant",
      intent: "Use Google Meet, realtime transcript/chat loops, and durable call handoffs.",
      best_for: [
        "joining or recovering live meetings",
        "feeding meeting decisions into orchestration queues",
        "testing OpenClaw-style talk loops with local bridges"
      ],
      safety:
        "live audio requires explicit approvals for capture, speech output, and notes/transcription",
      commands: [
        "jx meet session create --meeting <meet-url-or-code>",
        "jx meet session join <session-id> --runner browser-agent",
        "jx meet realtime watch <session-id> --chat-file tmp/meet-chat-input.txt",
        "jx meet realtime consult <session-id> --transcript <text>"
      ]
    },
    %{
      id: "remote",
      title: "Remote Discovery",
      intent:
        "Observe SSH and remote tmux surfaces without confusing shell panes with agent UIs.",
      best_for: [
        "finding remote work sessions",
        "probing shell panes safely",
        "reconciling moved or orphaned tmux sessions"
      ],
      safety: "remote probes are explicit and avoid sending shell scripts into agent UIs",
      commands: [
        "jx ssh ls",
        "jx ssh pane-probe --all --dry-run",
        "jx sessions remote --probe --target <ssh-target> --json",
        "jx sessions reconcile --observe --json"
      ]
    }
  ]

  @playbooks %{
    "tui" => %{
      entrypoint: "jx tui",
      checks: [
        "Read agenda, notifications, handoffs, delegation reviews, and heartbeat health.",
        "Use `jx next --json` when only one command should be chosen.",
        "Prefer this mode after a resume or context transition."
      ],
      signals: [
        "Agenda identifies a specific handoff, delegation review, wake, or managed session.",
        "Heartbeat is fresh or clearly stale.",
        "The next command is inspectable before any live send."
      ],
      switch_when: [
        "Use daemon when the portfolio only needs continued polling.",
        "Use session-control when one ref needs direct intervention.",
        "Use delegation when completed worker output needs review."
      ],
      handoff: "Summarize the selected ref, reason, and exact next command."
    },
    "daemon" => %{
      entrypoint: "jx orchestrator start --dry-run --replace",
      checks: [
        "Confirm `jx orchestrator status` is not already healthy unless replacing intentionally.",
        "Review `jx policy tiers` before enabling execution.",
        "Keep live sends gated through managed/task-owned sessions."
      ],
      signals: [
        "Heartbeats update at the configured interval.",
        "Monitor events and notifications continue to move.",
        "Errors remain empty in heartbeat snapshots."
      ],
      switch_when: [
        "Use tui if heartbeats go stale or errors appear.",
        "Use execute only after reviewing planned decisions.",
        "Use wake for scheduled inbox nudges instead of ad hoc polling loops."
      ],
      handoff: "Report daemon key, latest heartbeat time, errors, and focus refs."
    },
    "dry-run" => %{
      entrypoint: "jx orchestrate step --auto-plan --json",
      checks: [
        "Inspect planned decisions before enabling `--execute`.",
        "Verify session controls are accurate for directable refs.",
        "Check action safety tier for anything that would mutate live state."
      ],
      signals: [
        "Decisions are recorded as planned actions.",
        "No live pane input is sent.",
        "Events and recommendations explain why each action exists."
      ],
      switch_when: [
        "Use execute when planned actions are safe or explicitly approved.",
        "Use session-control if the plan depends on one managed ref.",
        "Use tui if the plan is ambiguous."
      ],
      handoff: "List planned action IDs, safety tier, and approval needed."
    },
    "execute" => %{
      entrypoint: "jx orchestrate step --execute --yes --auto-plan",
      checks: [
        "Run dry-run first when the action set is not already understood.",
        "Confirm each live send target is managed or task-owned.",
        "Confirm fresh capture exists before sending into a pane."
      ],
      signals: [
        "Executed/skipped results are written to `jx actions ls`.",
        "Monitor cursor advances when acknowledgement is enabled.",
        "Follow-up observations or profile changes are visible."
      ],
      switch_when: [
        "Use tui after execution to verify effects.",
        "Use held-release policy for commits, deploys, destructive actions, or releases.",
        "Use session-control when one send needs manual wording."
      ],
      handoff: "Report executed action IDs, skipped actions, and any residual operator gate."
    },
    "session-control" => %{
      entrypoint: "jx session inspect <ref> --json",
      checks: [
        "Capture the pane before sending input.",
        "Confirm the ref is managed or task-owned.",
        "Keep protected and ignored sessions out of direct sends."
      ],
      signals: [
        "The profile has objective, expected completion, and prompt status.",
        "A single ref is the focus.",
        "The next prompt is ready, draft, blocked, or intentionally empty."
      ],
      switch_when: [
        "Use watch when waiting for terminal evidence.",
        "Use tui after a send to re-check portfolio state.",
        "Use remote when the ref points at an SSH shell that needs tmux discovery."
      ],
      handoff:
        "Record ref, profile state, capture freshness, and the exact prompt sent or drafted."
    },
    "watch" => %{
      entrypoint: "jx watch add <ref> --goal <text> --success <pattern> --mode notify",
      checks: [
        "Use concrete success or blocker evidence.",
        "Pick `notify`, `hold`, or `prompt` deliberately.",
        "Keep prompt mode as draft-only unless execution later approves a send."
      ],
      signals: [
        "`watch.completed` or `watch.blocked` appears as a monitor event.",
        "Notifications record terminal evidence.",
        "Prompt or hold profile updates happen only after matched evidence."
      ],
      switch_when: [
        "Use session-control when the watch points to one ref that needs direction.",
        "Use daemon for continuous watch evaluation.",
        "Use tui when multiple watch notifications compete."
      ],
      handoff: "Report watch ID, matched pattern, mode, and resulting profile action."
    },
    "wake" => %{
      entrypoint: "jx wake --message <text> --project <name>",
      checks: [
        "Use immediate wake for external attention now.",
        "Use `--in`, `--at`, or `--every` for scheduled triggers.",
        "Treat wakes as inbox items; they do not authorize live sends."
      ],
      signals: [
        "`external.wake` appears in monitor events.",
        "Unread notification is visible in `jx notifications ls`.",
        "`jx next` can select the wake as the top item."
      ],
      switch_when: [
        "Use tui to triage wake notifications.",
        "Use daemon to run due scheduled triggers.",
        "Use session-control only after a wake maps to a specific managed ref."
      ],
      handoff: "Report wake ID or trigger ID, schedule, severity, project, and ref."
    },
    "delegation" => %{
      entrypoint: "jx delegate reviews --json",
      checks: [
        "Review write ownership and forbidden paths.",
        "Require evidence before accepting completed work.",
        "Keep integration decisions explicit: accept, revise, reject, or hold."
      ],
      signals: [
        "Delegation review includes evidence, warnings, and integration status.",
        "Accepted work has clear verification artifacts.",
        "Rejected or revised work has actionable feedback."
      ],
      switch_when: [
        "Use execute only after integration is accepted and policy allows it.",
        "Use tui when reviews compete with other urgent portfolio work.",
        "Use wake to schedule a follow-up review."
      ],
      handoff: "Report delegation ID, decision, evidence, risks, and changed paths."
    },
    "meet" => %{
      entrypoint: "jx meet session ls --json",
      checks: [
        "Confirm audio capture, speech output, and notes/transcription approvals.",
        "Keep decisions in call handoffs instead of free-form transcript notes.",
        "Recover existing sessions before creating duplicates."
      ],
      signals: [
        "Meet session status is live, recovered, ended, or failed.",
        "Realtime consults produce structured decisions and follow-ups.",
        "Call handoffs appear in call brief."
      ],
      switch_when: [
        "Use tui after the meeting creates handoffs.",
        "Use delegation when meeting decisions become bounded worker packets.",
        "Use held-release policy for public or externally visible outcomes."
      ],
      handoff: "Report meeting/session ID, decisions, follow-ups, and handoff IDs."
    },
    "remote" => %{
      entrypoint: "jx ssh pane-probe --all --dry-run",
      checks: [
        "Preview candidate SSH shell panes before probing.",
        "Do not send shell probes into agent UI panes.",
        "Prefer direct SSH probe when auth works."
      ],
      signals: [
        "Remote tmux sessions are saved as remote observations.",
        "Reconciliation identifies moved, duplicate, or orphaned sessions.",
        "Probe errors name the transport and target."
      ],
      switch_when: [
        "Use session-control after a remote session is reconciled to a ref.",
        "Use tui if remote discovery changes the active portfolio.",
        "Use manual policy when auth or shell identity is ambiguous."
      ],
      handoff: "Report target, probe command, discovered sessions, and any reconciliation risks."
    }
  }

  @mode_aliases %{}

  def all, do: @modes

  def ids do
    Enum.map(@modes, & &1.id)
  end

  def fetch(id) when is_binary(id) do
    normalized = normalize_id(id)
    Enum.find(@modes, &(&1.id == normalized))
  end

  def playbook(id) when is_binary(id) do
    case fetch(id) do
      nil ->
        {:error, :mode_not_found}

      mode ->
        {:ok,
         mode
         |> Map.merge(Map.fetch!(@playbooks, mode.id))
         |> Map.put(:available_modes, ids())}
    end
  end

  defp normalize_id(id) do
    normalized =
      id
      |> String.trim()
      |> String.downcase()
      |> String.replace("_", "-")

    Map.get(@mode_aliases, normalized, normalized)
  end
end
