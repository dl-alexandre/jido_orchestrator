# CLI Guide

The CLI is `jx`.

## First Commands

Initialize the database:

```bash
jx init
```

Register a local host:

```bash
jx host add local --local --workspace /tmp/jx
```

Register a project:

```bash
jx project add saysure --host local --repo /path/to/repo
```

Read a project gateway brief:

```bash
jx project brief saysure --json
```

Check host readiness:

```bash
jx host doctor local --agent codex
jx host doctor local --agent codex --transport acpx
```

## Choose A Mode

List operating modes or inspect one mode playbook:

```bash
jx modes
jx modes wake
jx modes playbook daemon --json
```

Mode playbooks include the entrypoint, checks, expected signals, and when to
switch to another mode.

## Read The TUI

Use these before deciding what to do:

```bash
jx tui
jx tui snapshot --no-observe
jx tui watch --interval-ms 5000
jx tui plan
jx call brief --observe --json
jx portfolio summary --json
jx sessions summary --observe --json
jx sessions queues --json
jx sessions profiles --type agent --json
jx orchestrator health --json
jx orchestrator heartbeats --json
```

`tui` is the default interactive terminal view. It brings together the next
action, daemon health, monitor-event cursor, portfolio counts, agenda items, and
project focus, then lets you move through the queue, acknowledge notifications
or inbox events, mark session controls, capture a ref, draft a prompt, or send a
confirmed steering prompt. Use `tui snapshot --no-observe` for a scriptable
stored-state read, or `tui watch` to redraw a non-interactive snapshot on an
interval.

## Read The Operator Dashboard

Use the dashboard for JX/DevIDE runner visibility without taking control-plane
actions:

```bash
jx dashboard
jx dashboard workspace <workspace-id>
jx dashboard runner <runner-id>
jx dashboard assignment <assignment-id>
jx dashboard action <action-id>
```

The dashboard surfaces queue state, runner fleet state, leases, assignments,
workspace health, replay/reconciliation state, failure summaries, and recent
timeline events from append-only operational evidence. It is read-only; DevIDE
still owns command authorization and execution.

## Provision Runtime Environments

Runtime commands manage isolated worktree placement for already approved safe
actions:

```bash
jx runtimes provision <action-id> --project <project> --runner <runner-id> --tool mix
jx runtimes assign <runtime-id> <action-id> --runner <runner-id>
jx runtimes ls --status active
jx runtimes show <runtime-id>
jx runtimes release <runtime-id>
```

Provisioning records lifecycle evidence and creates the worktree environment.
Assignment routes work to that environment by host, repo, tools, runtime id,
and runtime path. DevIDE still decides what command can execute.

## Manage The Daemon

Start the background loop:

```bash
jx orchestrator start --dry-run --replace
```

Check status:

```bash
jx orchestrator status
```

Read logs:

```bash
jx orchestrator logs -n 80
```

Check heartbeat-derived health alerts:

```bash
jx orchestrator health --json
```

Stop it:

```bash
jx orchestrator stop
```

## Wake The Inbox

Record an immediate external wake:

```bash
jx wake --message "review this incident" --project saysure
```

Schedule one-shot or recurring wakes:

```bash
jx wake add --message "check again" --in 30m --project saysure
jx wake add --message "review CI" --every 15m --project saysure
jx wake ls --status active
jx wake run-due --json
```

The daemon runs due triggers through the normal monitor event and notification
inbox. Wakes are attention signals, not live session sends.

## Discover And Observe Sessions

List discovered sessions:

```bash
jx sessions
jx sessions --json
```

Save observations:

```bash
jx sessions snapshot --type agent --save --json
jx sessions observe --type agent --json
```

Inspect one session:

```bash
jx session inspect s-abc123def0 --json
jx session capture s-abc123def0 -n 80
```

## Mark Session Policy

Allow a session to receive direction:

```bash
jx session mark s-abc123def0 --mode managed --project saysure
```

Ignore a session:

```bash
jx session mark s-abc123def0 --mode ignored
```

Protect a session:

```bash
jx session mark s-abc123def0 --mode protected
```

## Profile A Session

Set intent and a chambered prompt:

```bash
jx session profile s-abc123def0 \
  --objective "finish the assigned refactor" \
  --expect "after tests pass" \
  --next-prompt "Report status, blockers, changed files, and next step." \
  --prompt-status ready
```

Send a message:

```bash
jx session send s-abc123def0 "please report status"
```

## Assign Managed Work

Launch a managed worktree/tmux-backed task:

```bash
jx assign saysure "Create a noop file and report pwd/git branch" --agent codex
jx assign saysure "Create a noop file and report pwd/git branch" --agent codex --transport acpx
```

Then inspect:

```bash
jx status
jx attach task-abc123def456
jx logs task-abc123def456 -n 200
```

## Coordinate Safe-Action Agents

Fleet intake starts with the attention queue, then moves through approvals,
safe actions, assignments, and timelines:

```bash
jx queue ls --sort urgency
jx approvals show <approval-id>
jx actions propose <approval-id>
jx actions dry-run <action-id>
jx assignments create <action-id>
jx agents ls --status idle
jx assignments claim <assignment-id> --agent <agent-id>
jx assignments start <assignment-id> --agent <agent-id>
jx assignments execute <assignment-id> --agent <agent-id> --confirm
jx timeline assignment <assignment-id>
```

Agents are durable JX identities with capabilities and optional workspace
affinity:

```bash
jx agents register agent-1 \
  --capability safe_action:rerun_devide_command \
  --workspace ws-1
jx agents heartbeat agent-1
jx agents ls --status all
```

Assignments delegate only existing safe actions. They do not add shell access,
arbitrary argv, generic HTTP calls, proposal application, file writes, or agent
prompting.

```bash
jx assignments ls --status active
jx assignments progress <assignment-id> --agent agent-1 --summary "rerun queued"
jx assignments fail <assignment-id> --agent agent-1 --summary "policy denied"
jx assignments expire
```

Use `jx timeline agent <agent-id>`, `jx timeline assignment <assignment-id>`,
and `jx actions show <action-id>` to reconstruct the operator and agent evidence
trail after success, retryable failure, or stale-claim recovery.

## Coordinate Remote Runners

Remote runners are durable host/tmux identities for delegated safe-action work.
They claim assignments through their mapped agent identity, but JX still only
executes the stored safe action. Runner commands never become shell forwarding.

Register and observe a runner:

```bash
jx runners register runner-1 \
  --agent agent-runner-1 \
  --host build-host-1 \
  --capability safe_action:rerun_devide_command \
  --workspace ws-1 \
  --tmux-server jx \
  --tmux-session-prefix jx-runner-1
jx runners heartbeat runner-1
jx runners ls --status all
jx runners show runner-1
```

Claim an assignment into a durable session:

```bash
jx assignments claim <assignment-id> \
  --runner runner-1 \
  --session rsess-1 \
  --tmux-session jx-runner-1-work \
  --log-path ~/.jx/runners/rsess-1.log
jx sessions ls --status active
jx sessions show rsess-1
```

Inspect without hidden execution:

```bash
jx sessions logs rsess-1 --lines 80
jx sessions attach rsess-1
jx timeline session rsess-1
jx timeline runner runner-1
```

`sessions logs` prints stored log metadata only. `sessions attach` prints the
tmux command for the operator and does not run it.

Recover stale ownership:

```bash
jx sessions expire
jx assignments create <action-id>
jx assignments claim <new-assignment-id> --runner <live-runner-id>
jx timeline assignment <old-assignment-id>
```

Only one active runner session can own an assignment. Expired sessions release
the assignment claim and action lease so a live runner can safely continue from
fresh operator-visible evidence.
