# Orchestration Assessment

Status: current architecture assessment. Live metrics should come from `jx`
commands, not from this document.

Archived snapshots may exist in `docs/archive/` for historical reference.

## Summary

`jx` has the right core shape for agent-facing orchestration:

- The public identity is clean: executable `jx`, OTP app `:jx`, modules `JX.*`.
- Session inventory can model local panes, SSH panes, agent panes, and stored
  task/session records.
- Profiles carry planned state, expected completion, prompt readiness, risk,
  and observed actuals.
- The orchestrator can run as a detached daemon and report health/heartbeats.
- Actions, notifications, profiles, queues, and portfolio summaries give agents
  durable coordination surfaces instead of relying on terminal tails alone.

The main risk is operational drift: docs and briefs must point agents to live
commands and stable policy, not stale PR IDs or dated session counts.

## Current Strengths

- Identity and naming are now aligned around `jx`.
- Public docs use `JX_*` environment variables and `~/.jx` paths.
- The CLI exposes practical operator surfaces for sessions, portfolio state,
  daemon health, notifications, and policy review.
- The planner has a playbook extension point while preserving a safety gate for
  risky prompts.
- HexDocs can be generated locally for API and guide review.

## Gaps To Keep Visible

- Publishing is intentionally blocked until license, source links,
  maintainership, public module exposure, and package contents are confirmed.
- Delegation review workflows need strong ownership and evidence requirements
  wherever completed work is integrated.
- CI watch summaries should reconcile historical watch failures against the
  current head SHA before creating operator work.
- Parked sessions should be distinguishable from sessions that truly need an
  operator decision.
- Remote SSH panes need clear classification between probeable shells and agent
  UIs.

## Recommended Documentation Standard

- Keep living docs stable, command-oriented, and current-name-only.
- Put dated operational snapshots under `docs/archive/`.
- Regenerate HexDocs after public module or guide changes.
- Treat `mix docs` warnings as release blockers.
- Verify old implementation names do not reappear in current docs unless they
  are explicitly discussed as retired names.
