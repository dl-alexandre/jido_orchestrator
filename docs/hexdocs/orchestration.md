# Orchestration

jx separates observation, planning, and execution so the foreground agent
does not have to poll every pane manually.

## Observation

Observation captures session tails and derives a compact work state.

```bash
jx sessions observe --type agent --json
```

Observation is safe. It records what is visible and updates change history.

## Queues

Queues group sessions by the next useful action:

```bash
jx sessions queues --json
```

Common queue actions:

- `send-session`
- `observe`
- `adopt`
- `blocked-profile`
- `none`

Queues are useful for agents because they remove the need to scan every
individual session profile first.

## Project Brief

Project briefs narrow global orchestration state to one project:

```bash
jx project brief saysure --json
```

The packet includes the project portfolio row, call-brief agenda, next mode
guidance, notifications, CI watches, handoffs, delegations, scheduled wakes, and
commands to continue. Use it when the operator or primary agent has already
chosen a project and should avoid scanning unrelated work.

## Monitor Scan

The monitor scan turns current state into durable events and notifications.

```bash
jx monitor scan --json
```

It reads profiles, watches, queues, and due wake triggers, then emits compact
events like:

- session blocked
- session ready
- directive awaiting observation
- watch completed
- watch blocked
- delegation review needed
- external wake

## Wake Triggers

Wakes are durable inbox entries for scripts, recurring checks, and future
webhook adapters.

```bash
jx wake --message "review this incident" --project saysure
jx wake add --message "check again" --in 30m --project saysure
jx wake add --message "review CI" --every 15m --project saysure
jx wake ls --status active
```

Due triggers are emitted by `monitor scan`, `orchestrate step`, and the detached
daemon. They create `external.wake` monitor events and notifications; they do
not send prompts or bypass execution gates.

## Orchestrate Step

`orchestrate step` consumes events and planned decisions.

```bash
jx orchestrate step --execute --yes --auto-plan --json
```

It can:

- update profiles
- observe sessions after sends
- send chambered prompts when gated execution is allowed
- record action audit entries
- acknowledge consumed events

## Daemon

The orchestrator daemon runs the same loop in a detached tmux session.

```bash
jx orchestrator start --dry-run --replace
```

The daemon writes heartbeats to SQLite. Heartbeats summarize:

- top priority
- autonomous next action
- operator-needed reasons
- blocked, ready, awaiting, and stale counts
- due wake trigger counts
- focus refs

Read them with:

```bash
jx orchestrator health --json
jx orchestrator heartbeats --json
```

## Actions Audit

Every planned or executed decision is mirrored to actions:

```bash
jx actions ls --json
```

This is the accountability trail for autonomous orchestration.
