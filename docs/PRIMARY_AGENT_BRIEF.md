# Primary Agent Brief

Status: living runbook, not a live-state snapshot.

This document is for a primary agent operating `jx`. It describes the current
identity, operating boundary, and refresh commands. Do not treat any archived
brief as current portfolio state.

Archived snapshots may exist in `docs/archive/` for historical reference.

## Current Identity

- Product name and executable: `jx`
- OTP application: `:jx`
- Implementation namespace: `JX.*`
- Default database: `~/.jx/jx.db`
- Default runtime directory: `~/.jx`
- Workspace control directory: `.jx`
- Default tmux server name: `jx`
- Public environment variable prefix: `JX_`

Jido remains only as an upstream action/runtime concept where the code
explicitly integrates with Jido packages.


## First Read

Use current commands instead of relying on dated notes:

```bash
bin/jx tui snapshot --no-observe
bin/jx call brief --observe --json
bin/jx portfolio summary --json
bin/jx sessions queues --json
bin/jx orchestrator health --json
bin/jx notifications ls --status unread
```

For local code state, inspect the working tree directly before editing:

```bash
git status --short
git diff --stat
```

This workspace may not always be a git checkout, so a failed git command should
be treated as environment information rather than a product failure.

## Operator Boundary

Proceed autonomously when the scope is clear, the action is non-destructive,
tests or checks are appropriate for the change, and the diff is coherent.

Hold for explicit approval before:

- Force-pushing or rewriting published history.
- Deleting user data, worktrees, branches, or unreviewed files.
- Changing credentials, secrets, deploy targets, or release settings.
- Publishing packages, docs, or deployments to public services.
- Taking ownership of ambiguous work from another active agent.

## Work Loop

1. Refresh live state with `bin/jx call brief --observe --json`.
2. Identify ready queues, blocked queues, unread notifications, and current
   daemon health.
3. Pick one concrete next action with a clear owner and rollback boundary.
4. Inspect any affected repo or session before sending prompts or editing files.
5. Run the narrowest useful verification first, then broaden when the change
   touches shared behavior.
6. Record action evidence through the relevant CLI surface or in the final
   handoff.

## Documentation Boundary

Current docs should describe stable behavior and refresh commands. Dated PR
facts, session counts, CI run IDs, and portfolio snapshots belong in
`docs/archive/` or in generated command output, not in this living brief.
