# jx Overview

`jx` is a terminal control plane for durable agent orchestration.

It helps an operator or lead agent coordinate work that is already happening
across tmux panes, SSH sessions, local repositories, CI runs, approvals, and
long-running agent processes. `jx` is not a replacement for Codex, Claude, or
opencode. It is the operational layer around them.

## What It Solves

Agent work becomes difficult to operate when the state that matters lives only
in terminal scrollback, remote panes, CI tabs, branch names, and chat context.
`jx` records that state so work can be observed, resumed, audited, and gated
without forcing the foreground conversation to become a manual polling loop.

The durable records cover:

- hosts, projects, tasks, and worktrees
- tmux, SSH, and process-backed session inventory
- terminal observations and session profiles
- queues, watches, controls, handoffs, and wake triggers
- CI watches and GitHub check state
- approvals, safe actions, leases, assignments, and timelines
- orchestrator heartbeats and audit evidence

The durable record is the important part. A session can disappear, move, block,
finish, or need new input, and the orchestrator can still compare the latest
observation against the saved objective before deciding what to surface or
execute.

## When To Use It

Use `jx` when you need to:

- see many active coding sessions without manually inspecting every pane
- launch bounded agent work against registered projects
- reconnect live terminal state to saved objectives and profiles
- coordinate handoffs between foreground and background execution
- require explicit approval before risky, destructive, or public actions
- preserve evidence for what the orchestrator saw and decided

## First Commands

Install from Hex:

```bash
mix escript.install hex jido_orchestrator
```

Initialize local state and register a host:

```bash
jx init
jx host add local --local --workspace /tmp/jx
jx host doctor local --agent codex
```

Register a project and assign work:

```bash
jx project add my-app --host local --repo /path/to/my-app
jx assign my-app "Investigate the failing import flow" --agent codex
```

Read the operator surfaces first:

```bash
jx tui
jx sessions queues --json
jx project brief my-app --json
jx orchestrator heartbeats --json
```

## Core Loop

The normal operating loop is:

1. Discover active sessions.
2. Capture compact terminal observations.
3. Compare actual state to saved profiles and objectives.
4. Queue observations, profile updates, and gated actions.
5. Execute only the actions allowed by policy.
6. Persist decisions, notifications, timelines, and heartbeats.
7. Surface only meaningful decisions to the operator or foreground agent.

## Safety Boundary

`jx` can perform non-destructive orchestration when scope is clear. It holds for
explicit approval before destructive, public, or ambiguous actions.

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

## Naming

- Hex package: `jido_orchestrator`
- installed executable: `jx`
- OTP app: `:jx`
- Elixir modules: `JX.*`
- repository: `dl-alexandre/jido_orchestrator`

## Next Pages

- [Installation](installation.html)
- [Concepts](concepts.html)
- [CLI Reference](cli.html)
- [Orchestration](orchestration.html)
- [Safety Policy](safety_policy.html)
