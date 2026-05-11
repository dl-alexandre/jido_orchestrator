# Session Profiles

Session profiles are the main coordination layer for long-running agent work.

A terminal tail tells you what is visible now. A profile tells you what should
be happening.

## Fields

Profiles store:

- summary
- objective
- expected completion
- strategy
- notes
- owner
- risk level
- lifecycle status
- current hypothesis
- last evidence
- prompt status
- next prompt
- stale threshold
- last seen time

## Prompt Status

Prompt status controls whether the orchestrator may act:

- `none` means no prompt is chambered.
- `draft` means a possible prompt exists but is not ready to send.
- `ready` means a gated send can proceed when policy allows it.
- `sent` means observe before sending again.
- `blocked` means a human or lead agent decision is required.

## Lifecycle

Lifecycle communicates intent:

- `active` means keep tracking and progressing.
- `parked` means do not treat the session as urgent.
- `done` means the session completed its purpose.
- `blocked` means the profile needs decision or repair.

## Updating A Profile

```bash
jx session profile s-abc123def0 \
  --summary "PR #461 scale fix worker" \
  --objective "Get PR #461 CI green for current head" \
  --expect "after Test, Credo, and Desktop Tests pass" \
  --strategy "Patch only scale/dashboard paths unless CI proves otherwise" \
  --evidence "Current head 54e4b877; fresh CI in progress" \
  --stale-after 900
```

## Reading Profiles

```bash
jx sessions profiles --type agent --json
jx sessions profiles --prompt-status ready --json
jx sessions profiles --next send-session --json
```

## Agent Rule

If a profile is blocked, parked, or done, do not send broad prompts. Update the
profile or resolve the blocker first.

