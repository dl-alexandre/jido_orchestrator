# Delegation

Delegation is how the foreground or primary agent throws thought and scope to a
worker without blocking the main conversation.

## Delegation Packet

A useful delegation packet contains:

- project
- session ref
- worker kind
- owner
- brief
- context
- allowed write paths
- forbidden paths
- constraints
- acceptance criteria
- verification commands
- expected evidence

## Evidence

Evidence should be structured. A worker report is not enough by itself.

Use this shape:

```text
Command:
CWD:
Exit status:
Relevant output summary:
Changed files:
Artifacts reviewed:
Residual risk:
Next concrete step:
```

## Review

Completed delegations should be reviewed before integration.

Review decisions:

- `accept`
- `revise`
- `reject`
- `hold`

A delegation should not be accepted if:

- no structured evidence was recorded
- artifacts fall outside declared write paths
- changed files were not owned by the worker
- verification did not run
- residual risk is unclear

## Current Gap

Some delegation operations are available through `JX.Workspace` and
Jido actions before they are fully exposed as CLI commands. Until those CLI
commands are complete, use `call brief`, `portfolio summary`, notifications,
and direct Workspace/Jido action calls to inspect delegation review state.

The desired CLI shape is:

```bash
jx delegations ls --json
jx delegation inspect <id> --json
jx delegation evidence add <id> --command "..." --cwd "..." --exit 0 --summary "..."
jx delegation review <id> --decision accept --summary "..."
```

