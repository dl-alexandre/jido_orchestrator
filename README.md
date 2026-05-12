# jido_orchestrator

Durable agent orchestration from the terminal. `jx` is an agent-facing CLI and
TUI for orchestrating SSH/tmux-backed work sessions.

`jx` is its own orchestration implementation. It is not part of `CLI-Tools`;
external repositories such as `example-project` are target workspaces managed by
`jx`, not the implementation boundary for `jx`.

## Installation

Install from Hex:

```bash
mix escript.install hex jido_orchestrator
```

This installs the `jx` executable.

The durability unit is:

- an Ecto task record
- a remote git worktree and branch
- a remote `.jx/tasks/<task-id>/` directory
- a deterministic tmux session
- a pipe-pane log file

SSH is only the transport. Sessions are designed to survive local disconnects.

## Commands

```bash
bin/jx init
bin/jx modes
bin/jx modes wake
bin/jx tui plan
bin/jx tui
bin/jx tui snapshot --no-observe
bin/jx tui watch --interval-ms 5000
bin/jx next
bin/jx wake --message "external trigger: review new incident" --project saysure
bin/jx wake add --message "check handoff after standup" --in 30m --project saysure
bin/jx wake add --message "recurring CI review" --every 15m --project saysure
bin/jx wake ls --status active
bin/jx wake run-due --json
bin/jx host add build-1 --ssh developer@example.com --workspace /srv/agent
bin/jx host add local --local --workspace /tmp/jx
bin/jx host ls
bin/jx host doctor build-1 --agent codex
bin/jx host doctor build-1 --agent codex --transport acpx
bin/jx project add saysure --host build-1 --repo /srv/repos/saysure
bin/jx project brief saysure --json
bin/jx assign saysure "refactor webhook ingestion boundary" --agent codex
bin/jx assign saysure "refactor webhook ingestion boundary" --agent codex --transport acpx
bin/jx fanout plan test-coverage --baseline 53907e03
bin/jx fanout status test-coverage-2026-05-08
JX_DEVIDE_URL=http://localhost:4000 JX_DEVIDE_API_TOKEN=... bin/jx devide portfolio
JX_DEVIDE_URL=http://localhost:4000 JX_DEVIDE_API_TOKEN=... bin/jx devide watch --state --interval-ms 5000
JX_NOTIFICATION_FILE=notifications.jsonl bin/jx devide watch --state --interval-ms 5000
bin/jx portfolio summary
bin/jx approvals ls
bin/jx actions show act-abc123def0
bin/jx actions history apr-abc123def0
bin/jx actions propose apr-abc123def0
bin/jx actions dry-run act-abc123def0
bin/jx actions execute act-abc123def0 --confirm
bin/jx operate --observe --json
bin/jx operate --observe --execute safe --json
bin/jx operate --observe --execute rec-abc123def0 --yes --json
bin/jx manage --iterations 1 --json
bin/jx work ls --type agent --json
bin/jx operations ls --json
bin/jx controls ls --json
bin/jx remote ls --json
bin/jx meet plugin --json
bin/jx meet auth configure --client-id "$GOOGLE_OAUTH_CLIENT_ID" --client-secret-env GOOGLE_OAUTH_CLIENT_SECRET --artifacts
bin/jx meet auth url --profile personal
bin/jx meet session create --meeting https://meet.google.com/abc-mnop-xyz --chrome-node http://127.0.0.1:9222 --paired-chrome-node http://127.0.0.1:9223 --twilio-stream-url wss://voice.example.com/meet
bin/jx meet session join met-abc123def0 --runner browser-agent --browser-agent-command "$JX_MEET_BROWSER_AGENT_CMD"
bin/jx meet realtime plan met-abc123def0 --json
export JX_MEET_BROWSER_REALTIME_CMD="$PWD/bin/meet-browser-realtime"
export JX_MEET_CONSULT_CMD="$PWD/bin/meet-consult-codex"
export JX_MEET_BROWSER_SPEECH_OUT_CMD="$PWD/bin/meet-speech-output"
bin/jx meet realtime watch met-abc123def0 --browser-agent-command "$JX_MEET_BROWSER_REALTIME_CMD" --consult-command "$JX_MEET_CONSULT_CMD" --speak --iterations 0
bin/jx meet realtime watch met-abc123def0 --chat-file tmp/meet-chat-input.txt --speak --speech-output-command scripts/meet_chat_output_queue.sh --iterations 0
OPENAI_API_KEY=... scripts/meet_audio_chat_bridge.sh met-abc123def0
bin/jx meet realtime consult met-abc123def0 --transcript "Decision: wait for CI" --follow-up "review blockers"
bin/jx meet recover --debug-url http://127.0.0.1:9222 --meeting abc-mnop-xyz --json
bin/jx meet sync met-abc123def0 --json
bin/jx meet export met-abc123def0 --dir ./meet-artifacts
bin/jx discover
bin/jx discover --managed
bin/jx discover --host build-1
bin/jx activity --all-processes
bin/jx sessions
bin/jx sessions --all-processes
bin/jx sessions --json
bin/jx sessions --type ssh --action force-probe --json
bin/jx sessions snapshot --type agent -n 20 --json --compact
bin/jx sessions summary --observe --json
bin/jx sessions queues --json
bin/jx sessions dossiers --type agent --json
bin/jx sessions profiles --type agent --json
bin/jx sessions profiles --prompt-status ready --json
bin/jx monitor scan --json
bin/jx orchestrate step --execute --yes --auto-plan
bin/jx orchestrator start --dry-run --replace
bin/jx orchestrator status
bin/jx orchestrator logs -n 80
bin/jx orchestrator health --json
bin/jx orchestrator heartbeats --json
bin/jx actions ls --status planned --json
bin/jx notifications ls --status unread
bin/jx notifications ack --all
bin/jx policy tiers
bin/jx policy overview
bin/jx sessions dossiers --next resolve-repo-blocker
bin/jx sessions dossiers --next send-session --control managed
bin/jx sessions reconcile --json
bin/jx sessions snapshot --type agent --work-state blocked
bin/jx sessions snapshot --type agent --save
bin/jx sessions observe --type agent --json
bin/jx sessions history --work-state idle
bin/jx sessions changes --attention --json
bin/jx sessions stale --type agent --seconds 600
bin/jx sessions broadcast "please report current status" --work-state waiting
bin/jx sessions remote --json
bin/jx sessions remote --probe --target developer@example.com --json
bin/jx sessions remote --probe --force --target developer@example.com --json
bin/jx session capture s-abc123def0 -n 80
bin/jx session inspect s-abc123def0 --json
bin/jx session profile s-abc123def0 --objective "finish the assigned refactor" --expect "after tests pass" --next-prompt "Report status, blockers, and next step." --prompt-status ready
bin/jx session send s-abc123def0 "please report status"
bin/jx session mark s-abc123def0 --mode managed --project saysure --note "ok to direct"
bin/jx session mark s-abc123def0 --mode ignored
bin/jx session mark s-abc123def0 --mode protected
bin/jx session unmark s-abc123def0
bin/jx session probe s-abc123def0 --json
bin/jx session adopt s-abc123def0 saysure --agent codex
bin/jx watch add s-abc123def0 --goal "wait for tests" --success "0 failures" --mode prompt --prompt "Summarize the diff and next step."
bin/jx watch add s-abc123def0 --goal "stop on auth failures" --blocker "Permission denied" --mode hold
bin/jx watch ls
bin/jx watch review wat-abc123def0
bin/jx ssh ls
bin/jx ssh probe --target developer@example.com
bin/jx ssh pane-probe --all --dry-run
bin/jx ssh pane-probe --all
bin/jx ssh pane-probe --all --target build-1-remote
bin/jx ssh pane-probe --server default --session mm --window 0 --pane 1
bin/jx tmux ls build-1 --all
bin/jx tmux attach build-1 jx_saysure_task_abc123_codex --server default
bin/jx tmux stop build-1 stale_session --server socket:agenttest
bin/jx task adopt-tmux saysure --session jx_saysure_task_abc123_codex --server default --worktree /srv/agent/projects/saysure/worktrees/task-abc123 --agent codex
bin/jx task send task-abc123def456 "status update?"
bin/jx operator profile --json
bin/jx operator profile set --preferences "agent-led orchestration; keep sends gated; resolve repo blockers first"
bin/jx directives ls -n 20
bin/jx status
bin/jx attach task-abc123def456
bin/jx logs task-abc123def456 -n 200
bin/jx stop task-abc123def456
bin/jx ci digest 1234 --repo acme/app
bin/jx ci watch 1234 --repo acme/app --mode notify
bin/jx ci watches --status active --json
bin/jx ci review wat-abc123def0
bin/jx ci cancel wat-abc123def0
bin/jx promote preflight saysure --from develop --to main
bin/jx promote run saysure --from develop --to main
bin/jx runners register runner-1 --agent codex --host build-1 --capability shell
bin/jx runners heartbeat runner-1 --json
bin/jx runners ls --status idle --json
bin/jx runners show runner-1 --json
bin/jx assignments create act-abc123def0 --ttl-seconds 1800
bin/jx assignments ls --status active --json
bin/jx assignments claim asg-abc123def0 --runner runner-1
bin/jx assignments start asg-abc123def0 --agent codex
bin/jx assignments progress asg-abc123def0 --agent codex --summary "phase 1 complete"
bin/jx assignments execute asg-abc123def0 --agent codex --confirm
bin/jx assignments fail asg-abc123def0 --agent codex --summary "auth blocker"
bin/jx assignments expire --json
bin/jx runtimes provision act-abc123def0 --project saysure --branch-isolation worktree
bin/jx runtimes assign rt-abc123def0 act-abc123def0 --runner runner-1
bin/jx runtimes ls --status ready --json
bin/jx runtimes show rt-abc123def0
bin/jx runtimes release rt-abc123def0
bin/jx leases ls --status active --json
bin/jx leases acquire approval apr-abc123def0 --owner operator-1 --ttl-seconds 900
bin/jx leases release lse-abc123def0
bin/jx leases reassign approval apr-abc123def0 --owner operator-2
bin/jx timeline assignment asg-abc123def0 -n 100 --json
bin/jx timeline workspace ws-abc123def0
bin/jx timeline action act-abc123def0
```

Use `--db path/to/jx.db` or `JX_DB=path/to/jx.db` to override the default SQLite database at `~/.jx/jx.db`. Approval attention events log to the console by default; set `JX_NOTIFICATION_FILE=notifications.jsonl` to append redacted JSONL under the JX state directory. `JX_STATE_DIR` overrides that directory; otherwise the file sink uses the `JX_DB` directory or `~/.jx`.

For local dogfooding without invoking Mix on every command, build the escript and run the wrapper against it:

```bash
mix escript.build
JX_USE_ESCRIPT=1 bin/jx sessions queues
```

The escript extracts runtime-only app/dependency files, including migrations and native NIFs, into `~/.jx/runtime` and tzdata release files into `~/.jx/tzdata`. Set `JX_TZDATA_DIR` if that cache needs to live elsewhere.

Tmux server names come from discovery. Managed tasks use `jx` by default; existing user sessions normally appear as `default`; additional tmux sockets appear as `socket:<name>`.

`project brief <name>` is the project gateway. It narrows portfolio state, call brief agenda, notifications, CI watches, handoffs, delegations, scheduled wakes, and next mode guidance to one registered or active project. Use it when a primary agent should work one project without stitching together several global JSON commands.

`fanout` is the file-backed control-plane primitive for multi-host assignment
runs. `jx fanout plan` writes a durable run directory containing
`run_manifest.json`, `agent_packet.md`, `preflight_report.md`, per-assignment
JSON records, and append-only report directories. Assignment records are mutable
control-plane state owned by `jx`; accepted/rejected reports are immutable
execution-plane evidence produced by agents. The prose packet is human-readable
policy and task context; the manifest and assignment JSON files are the
executable source of truth.

`tui plan` prints the service runbook: the monitor loop, decision gates, primary surfaces, and success criteria for operating jx without foreground polling. `tui` is the default interactive terminal surface. It combines the next action, portfolio counts, daemon heartbeat health, monitor-event cursor state, agenda items, project focus, and suggested commands in one steerable view where you can select queue items, acknowledge inbox work, mark session controls, capture refs, draft prompts, and send confirmed steering prompts. Use `tui snapshot --no-observe` for a scriptable one-shot view, or `tui watch --interval-ms 5000` to keep a non-interactive snapshot refreshed.

`sessions` is the management view. It combines tmux panes, live agent/SSH processes, registered task records, and actionable commands such as `attach`, `capture`, `adopt`, `send`, `task-send`, `logs`, `stop`, and `pane-probe`. Each row has a stable `REF` for the current inventory, which can be used with `session inspect`, `session capture`, `session attach`, `session send`, and `session probe`. `sessions snapshot` captures pane tails and classifies current work as `blocked`, `running`, `waiting`, `idle`, `unknown`, or `unobservable`; use `--work-state` to focus the management view. Add `--save` to persist observations, then use `sessions history`, `sessions changes`, or `sessions stale` to review recent observed state and transitions. `sessions summary --observe --json` is the operator dashboard: it refreshes observations, reports attention/stale/reconciliation state, groups sessions by workspace cluster, and lists remote SSH targets that need safe probing. `sessions dossiers` is the agent-oriented compact view: it records a fresh observation by default, joins the current work board to recent changes and directives, reports repository blockers/risks, and emits a suggested next action plus handoff context per session. `sessions profiles` layers saved session intent over dossiers: objective, expected completion, chambered next prompt, prompt status, and a comparison against observed state. Use `session profile <ref>` to update a session plan and `operator profile` to record operator preferences. Use `--next resolve-repo-blocker`, `--next send-session`, `--next adopt`, or `--next mark-managed` to pull focused work queues for orchestration. `sessions queues` groups those dossiers into action queues in one call, which is the preferred agent entrypoint for deciding what to do next.

`operate --observe --json` is the machine-oriented orchestration view. It emits stable recommendation IDs and separates `safe`, `gated`, and `manual` actions. `operate --execute safe` runs only safe read-only actions. `operate --execute <rec-id> --yes` is required before gated actions can send input into a pane. Gated force-probe execution is limited to remote SSH shell recommendations with a concrete session ref; SSH panes that appear to be agent UIs are manual remote-discovery items because they need direct SSH auth or an actual shell prompt. Attention recommendations remain operator-direction blockers. Execution attempts are audited and can be reviewed with `operations ls`. `manage --policy conservative` runs a finite orchestration loop that observes current sessions and executes only safe recommendations, which makes it suitable for agent-driven polling without silently mutating live panes. `work ls` is the operator work board: it captures current pane state, infers a task label from task metadata or pane output, shows local Git health for the pane path, and shows the next allowed action such as `mark-managed`, `send`, `adopt`, or `capture`.

Session controls are persistent operator policy for discovered sessions. Use `session mark <ref> --mode managed` when a live session is allowed to receive direction, `--mode ignored` when it should disappear from recommendations, and `--mode protected` when it must not be directed. `controls ls` shows current marks. `session send` and `sessions broadcast` require either a task-owned session or a `managed` mark plus a fresh successful capture before sending input.

Remote discovery observations created by successful pane probes are saved separately from local session inventory. Use `remote ls` to review remote tmux sessions discovered behind SSH panes; `sessions summary --observe --json` and `operate --observe --json` include the latest discovered remote groups alongside current local SSH/tmux inventory.

`meet` is the bundled Google Meet participant plugin. It supports personal
Google OAuth profiles, Chrome remote-debugging join/recovery plans, paired
Chrome nodes for observer/rescue workflows, Twilio Media Stream TwiML
generation, Meet attendance/artifact sync, and exports into a session artifact
directory. Recovered or newly created Meet sessions can also create `meet` call
handoffs so decisions and follow-up work stay visible to `call brief` and the
daemon.

`monitor scan` records compact orchestration events from current profiles, queues, watches, and due wake triggers. It also raises durable notifications for blocked/ready/watch/wake events. `orchestrate step` consumes those events and may execute safe profile updates, observations, and gated sends when `--execute --yes` is supplied. Every planned/executed decision is mirrored to `actions ls`, and every daemon loop writes a SQLite heartbeat visible through `orchestrator heartbeats`; stale/error heartbeat health is summarized by `orchestrator health`. Heartbeats include a guidance snapshot: `top_priority`, `autonomous_next`, `operator_needed_for`, counts for blocked/ready/awaiting/stale sessions, due wake triggers, and focus refs. That lets an agent decide whether to keep letting the daemon run, intervene in a session, or bring the operator in for an actual policy/strategy decision. `orchestrator start --dry-run` runs that loop in a detached tmux session without executing or acknowledging decisions; omit `--dry-run` when the daemon should advance policy-allowed work. Durable watches let the daemon react to terminal evidence: `--mode notify` only records `watch.completed` or `watch.blocked`, `--mode prompt` chambers a draft profile prompt after success, and `--mode hold` blocks the profile for review after success or blocker evidence. The next daemon iteration then treats that profile state like any other planned work. `sessions reconcile` compares active local refs against remote tmux observations so moved/orphaned sessions do not disappear silently. `policy overview` encodes the current autonomous boundary: commit/push/PR/rerun-CI are allowed when scope is clear and tests are green; force-pushes, destructive deletes, credential changes, public releases, and deploys stay held for explicit approval.

`ci` tracks GitHub PR check runs. `ci digest` summarizes the latest checks for a PR; `ci watch` registers a durable watch tied to a session ref or project with `--mode notify|hold|prompt` so the daemon reacts when checks settle; `ci watches` lists active/passed/failed watches; `ci review` re-evaluates a watch on demand; `ci cancel` retires one.

`promote` runs branch-promotion preflight and execution against a registered project. `promote preflight <project> --from <src> --to <dst>` reports eligibility without changing state; `promote run` performs the promotion when preflight is green. Promotion is gated by the same repo/CI checks surfaced through `ci` and `repo doctor`.

`runners`, `assignments`, `runtimes`, and `leases` are the durable execution-plane primitives backing `assign`/`fanout`. `runners` register and heartbeat the worker pool that claims work. `assignments` are the assignable units derived from an action: `create`, `ls`, `claim`, `start`, `progress`, `execute`, `fail`, `expire`. `runtimes` are provisioned execution environments (host + worktree + tool capabilities) bound to an action and optionally to a runner. `leases` enforce single-owner mutual exclusion over an approval, action, or workspace with a TTL — acquire one before mutating shared state, release or reassign when done. These commands are normally driven by the daemon; reach for them directly when an assignment is stuck, a runner is stale, or you need to audit who owns a resource.

`timeline <scope> <id>` reconstructs the event history for a workspace, approval, action, assignment, agent, runner, or session by replaying the durable event log. Use it to audit how a record reached its current state.

`wake` is the lightweight external-trigger entrypoint. `wake --message` records
an immediate `external.wake` monitor event plus unread notification, so scripts,
future webhooks, or a human operator can place a durable item into `call brief`,
`notifications ls`, and `jx next`. `wake add` persists one-shot or recurring
triggers using `--at`, `--in`, or `--every`; `monitor scan`, `orchestrate step`,
and `orchestrator start` run due triggers through the same inbox path.

`ssh pane-probe` is for already-open SSH shell panes found by `ssh ls` or `activity`. It sends a marker-wrapped read-only tmux inventory script through explicit outbound SSH panes, then captures only the marked output. Use `--all --dry-run` to preview candidate panes, `--all` to scan every discovered SSH pane, or pass `--session` with `--server`, `--window`, and `--pane` to probe one pane. Do not use pane probing through a remote Claude/opencode/Codex UI; use direct `ssh probe` when auth works, or attach/capture the pane and manage the agent UI as a local tmux-backed session.

Agent launch commands are template-driven. Override binaries with `JX_CLAUDE_BIN`, `JX_OPENCODE_BIN`, or `JX_CODEX_BIN`; override full command templates with `JX_CLAUDE_CMD`, `JX_OPENCODE_CMD`, or `JX_CODEX_CMD`. Use `--transport acpx` on `assign` or process-only `session stream-adopt --relaunch` to run the selected agent through the experimental ACP client transport. Override that binary with `JX_ACPX_BIN` and its command template with `JX_ACPX_CMD`.

Available template variables are shell-quoted when rendered:

- `{{agent_bin}}`
- `{{prompt_path}}`
- `{{worktree_path}}`
- `{{task_dir}}`
- `{{log_path}}`
- `{{task_id}}`
- `{{agent_name}}`

## Remote Layout

```text
<workspace>/
  projects/
    <project>/
      worktrees/
        <task-id>/
      .jx/
        tasks/
          <task-id>/
            task.json
            prompt.md
            launch.sh
            launch.run
            launched_at
            exit_status
            session.log
            artifacts/
```

## Development

```bash
mix deps.get
mix test
mix compile
bin/jx version
```

The public domain API is `JX.Workspace`, with execution behind `JX.SSH`. SSH hosts use the system `ssh` executable; local hosts use the same behaviour without SSH so worktree, tmux, and log handling can be tested without remote auth.

Jido is wired as a thin supervised runtime layer. `JX.Jido` starts under the application supervisor, `JX.Jido.Actions.*` wraps Workspace operations as validated Jido actions, and `JX.OrchestratorAgent` keeps compact orchestration state such as managed totals, directable totals, attention count, and repository blocker count. Keep SSH/tmux/Git policy in `Workspace`; Jido actions should delegate there instead of bypassing existing safety checks.
