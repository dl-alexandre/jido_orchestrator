# Safety Policy

jx is designed for agent-led work, but not for uncontrolled mutation.

The autonomous boundary is intentionally explicit.

## Safe Without Extra Approval

Allowed when scope is clear and non-destructive:

- inspect sessions
- capture terminal panes
- update profiles
- record handoffs
- add watches
- run targeted tests
- run formatting
- rerun CI
- make scoped commits
- push scoped branches
- open or update draft PRs

## Hold For Approval

Hold before:

- force-pushing
- deleting destructive state
- changing credentials or secrets
- deploying
- creating public releases
- changing broad unrelated code
- merging ambiguous worker output
- directing protected sessions

## Session Direction Rules

Do not send input to a pane unless:

- the session is task-owned or marked `managed`
- a fresh successful capture exists
- the action is allowed by policy
- the profile says the prompt is `ready`, or the operator/lead agent has chosen the send

Do not probe SSH panes that appear to be agent UIs with shell scripts. Use
direct SSH auth, a shell pane, or manage the agent UI as a tmux-backed session.

## Evidence Rules

Before accepting worker output:

- inspect changed files
- confirm ownership
- confirm commands and exit status
- record residual risk
- update the profile or delegation review

