# jx Overview

jx is a terminal control plane for durable agent work.
It lets an agent discover, profile, direct, and monitor work that is already
running across local tmux panes, SSH panes, and long-lived agent processes.

## What It Is

jx is not a chat UI and it is not a replacement for Codex, Claude, or
opencode. It is the layer that lets an agent coordinate those tools without
turning the foreground conversation into a polling loop.

The system persists:

- hosts and projects
- task records
- tmux session metadata
- terminal observations
- session controls
- session profiles
- session watches
- CI watches
- delegation packets
- call handoffs
- notifications
- orchestrator heartbeats
- action audit logs

The durable record is the important part. A session can disappear, move, block,
finish, or need a new prompt, and the orchestrator can still compare the latest
observation against the planned objective.

## Core Loop

The normal operating loop is:

1. Discover active sessions.
2. Capture compact terminal observations.
3. Compare actual state to saved profiles.
4. Queue safe observations, profile updates, and gated sends.
5. Execute only the actions allowed by policy.
6. Persist decisions, notifications, and heartbeats.
7. Surface only meaningful decisions to the foreground agent or Dalton.

The foreground agent should read the brief surfaces first:

```bash
jx call brief --observe --json
jx portfolio summary --json
jx sessions queues --json
jx orchestrator heartbeats --json
```

## Naming

Public names:

- product: `jx`
- CLI: `jx`
- tagline: durable agent orchestration from the terminal

Implementation names:

- OTP app: `:jx`
- modules: `JX.*`
- primary CLI: `jx`

## Safety Boundary

jx can perform non-destructive orchestration when scope is clear. It
should hold for explicit approval before destructive, public, or ambiguous
actions.

Allowed when scope is clear:

- read-only inspection
- session observation
- profile updates
- safe local tests
- scoped commits and pushes
- draft PR updates
- CI reruns

Held for explicit approval:

- force pushes
- destructive deletes
- credential changes
- public releases
- deploys
- broad cleanup work
- protected or ignored sessions
