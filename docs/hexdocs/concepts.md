# Concepts

jx uses a small set of durable concepts. Understanding these names makes
the CLI and JSON output much easier to read.

## Host

A host is a place where work can run.

It can be:

- local, using the local shell directly
- SSH-backed, using the system `ssh` executable

Hosts define the workspace root where project worktrees and task artifacts are
stored.

## Project

A project binds a name to a host and a repository path.

Projects let the orchestrator answer questions like:

- which repo owns this session?
- where should a task worktree be created?
- what project should notifications and profiles belong to?

## Task

A task is a durable launched unit of work. Managed tasks create:

- an Ecto task record
- a remote or local worktree
- a branch
- a `.jx/tasks/<task-id>/` directory
- a deterministic tmux session
- a pipe-pane log file

Task sessions are durable across local disconnects.

## Session

A session is a discovered active thing that may be useful to manage:

- tmux pane
- task-owned tmux pane
- SSH pane
- agent UI pane
- process-only agent

Each discovered session receives a stable ref for the current inventory, such
as `s-abc123def0`.

## Control

Controls are persistent policy marks for discovered sessions:

- `managed` means jx may direct the session when fresh capture and policy allow it.
- `ignored` means the session remains visible for inventory but should not produce work.
- `protected` means the session must not be directed.
- `uncontrolled` means no operator policy has been recorded yet.

## Observation

An observation is a saved snapshot of a session's current terminal tail and
derived work state.

Work states include:

- `blocked`
- `running`
- `waiting`
- `idle`
- `unknown`
- `unobservable`

## Profile

A profile stores intent for a session:

- objective
- expected completion
- strategy
- prompt status
- chambered next prompt
- lifecycle status
- risk level
- evidence

Profiles are what let agents compare "what should be happening" to "what the
terminal currently shows."

## Watch

A watch is a durable condition attached to a session or PR. Watches can notify,
hold, or chamber a follow-up prompt when evidence appears.

## Delegation

A delegation is a packet of work handed to another agent. It should include
write ownership, constraints, acceptance criteria, verification, and evidence.

Delegations are not safe to integrate just because they are complete. The
foreground or primary agent should review evidence and ownership first.

## Call Handoff

A call handoff stores decisions or follow-up work that came from a synchronous
surface such as a call, meeting, or chat.

It gives voice and meeting surfaces the same durable path into the orchestrator
as terminal sessions.
