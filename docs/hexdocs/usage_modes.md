# Usage Modes

`jx` is a TUI for durable agent work, not only a command launcher. The useful
operating mode depends on how much autonomy, background execution, and surface
integration you want at that moment.

This page captures the mode map exposed by `jx modes`. It is informed by
OpenClaw's model of explicit gateway, session, scheduler, sandbox, channel, and
voice/talk modes, but uses this project's existing primitives: tmux-backed
sessions, profiles, watches, monitor events, call handoffs, delegation reviews,
and Google Meet participant sessions.

## Quick Choice

| Need | Mode | First command |
| --- | --- | --- |
| Understand what is happening now | Terminal UI | `jx tui` |
| Let the system keep watching in the background | Detached Daemon | `jx orchestrator start --dry-run --replace` |
| Preview orchestration without live sends | Dry-Run Planning | `jx orchestrate step --auto-plan --json` |
| Execute policy-allowed queued work | Gated Execution | `jx orchestrate step --execute --yes --auto-plan` |
| Direct one session intentionally | Directed Session Control | `jx session profile <ref> ...` |
| React to terminal evidence later | Durable Watches | `jx watch add <ref> ... --mode notify|hold|prompt` |
| Wake the inbox from outside the loop | External Wake | `jx wake add --message ... --in 30m` |
| Review parallel worker output | Delegation Review | `jx delegate reviews --json` |
| Use a meeting or talk surface | Meeting Participant | `jx meet realtime watch <session-id> ...` |
| Discover remote tmux sessions | Remote Discovery | `jx ssh pane-probe --all --dry-run` |

## OpenClaw Lessons We Adopt

- Name the modes. A long help screen is not enough when the same tool can be a
  terminal UI, background daemon, live meeting participant, or delegated work
  reviewer.
- Keep gateway-like state durable. `jx` stores profiles, watches, notifications,
  action audits, handoffs, and heartbeats so a foreground agent does not need to
  poll every pane continuously.
- Separate session identity from delivery surface. The same work can be driven
  from tmux, daemon loops, call handoffs, or Meet realtime input, but the session
  profile remains the durable source of intent.
- Make automation modes explicit. `notify`, `hold`, and `prompt` watches map to
  different safety behavior; `dry-run`, `execute`, and `execute+ack` do the same
  for orchestrator loops.
- Gate live or externally visible surfaces. Meeting audio capture, speech output,
  protected sessions, ignored sessions, destructive work, and ambiguous ownership
  need explicit approval or review.

## Command Reference

Run:

```bash
jx modes
jx modes --json
jx modes tui
jx modes wake
jx tui
jx tui snapshot --no-observe
jx tui watch --interval-ms 5000
jx tui plan
jx modes playbook wake --json
jx next
jx next --json
jx wake --message "external trigger: review new incident" --project saysure
jx wake add --message "check this again" --in 30m --project saysure
jx wake add --message "recurring CI review" --every 15m --project saysure
jx wake ls --status active
jx wake run-due --json
jx policy tiers
```

The `modes` JSON form is intended for agents and other tooling that need to
choose an entrypoint programmatically. `jx modes <mode>` returns a concrete
playbook for one mode: entrypoint, pre-checks, signals, switch criteria, and
handoff guidance. `jx next` consumes the live call brief and returns one
recommended action, mode, and command.

`jx policy tiers` exposes the safety vocabulary behind those modes:
`inspect`, `safe`, `gated`, `manual`, and `held-release`. This is the local
equivalent of an OpenClaw-style sandbox/tool-access ladder: `jx` does not
currently sandbox arbitrary tools, so its safety boundary is expressed through
session controls, fresh-capture gates, action audit logs, and explicit release
holds.

`jx wake` is the narrow external-trigger primitive. `jx wake --message` records
a durable `external.wake` event and notification immediately. `jx wake add`
stores one-shot or recurring triggers using `--at`, `--in`, or `--every`, and
the normal monitor/orchestrator loop runs due triggers through the same event and
notification path. This is still not a webhook server; it gives scripts, future
webhook adapters, Jido actions, and human operators a stable ingress path
without bypassing the existing orchestration inbox.
