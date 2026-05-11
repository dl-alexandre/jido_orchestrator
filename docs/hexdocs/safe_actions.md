# Safe Actions

Safe actions are approval-gated ledger entries for tightly scoped operator
actions. M30 adds the first execution path: rerun one allowlisted DevIDE command
through DevIDE's own run endpoint after explicit confirmation. The second
supported action is `acknowledge_approval`, a JX-only acknowledgment of an open
approval item.

M31 adds replay resistance and an immutable audit trail. The mutable
orchestration action row remains the current state; `safe_action_events` is the
append-only record of what happened. Every action receives a `correlation_id`
that is copied into safe-action events, the DevIDE request header, the stored
DevIDE response envelope, and approval acknowledgment events.

## Current Contract

Executable action kinds:

- `rerun_devide_command`
- `acknowledge_approval`

No other action kinds are supported.

## Action-Kind Registry

Safe-action kind behavior is centralized behind `JX.SafeActions.Kind` callbacks
and the explicit `JX.SafeActions.Registry`. The registry contains exactly:

- `JX.SafeActions.Kinds.RerunDevIDECommand`
- `JX.SafeActions.Kinds.AcknowledgeApproval`

Each kind owns its proposal policy, stored-action authorization, dry-run result,
execution path, audit payload shape, target/would-do text, contract label, and
operator recovery guidance. `JX.SafeActions` owns the common ledger shell:
record lookup, replay/expiry/revocation checks, correlation ID creation, and
append-only event recording.

### DevIDE Command Rerun

Allowed DevIDE command IDs:

- `compile`
- `test`
- `format`
- `precommit`

Required inputs:

- an existing active approval item
- a stored JX DevIDE workspace snapshot
- a `failed_run` approval whose command ID is allowlisted
- DB isolation of `local`, `ephemeral`, or `unknown`

Denied inputs:

- dismissed or missing approval items
- missing workspace snapshots
- approval kinds that do not map to a deterministic rerun
- DB isolation of `shared_stage` or `unsafe`
- unrecognized DB isolation values
- command IDs outside the allowlist
- already executed actions
- expired or revoked actions
- actions whose stored approval/workspace/command evidence no longer matches
  the live approval

### Approval Acknowledgment

`acknowledge_approval` marks an open JX approval item as acknowledged. It does
not call DevIDE and does not require a workspace snapshot.

Required inputs:

- an existing open approval item
- source `devide`

Denied inputs:

- missing approval items
- already acknowledged or dismissed approval items
- expired or revoked actions
- actions whose stored approval/workspace evidence no longer matches the live
  approval

## Commands

```bash
jx actions show <action-id>
jx actions history <approval-id>
jx actions propose <approval-id> [--kind rerun_devide_command|acknowledge_approval] [--owner <owner>]
jx actions dry-run <action-id> [--owner <owner>]
jx actions execute <action-id> --confirm [--owner <owner>]
```

`propose` records a planned action in the existing orchestration actions ledger.
It does not call DevIDE. Without `--kind`, it proposes the original
`rerun_devide_command` action. Use `--kind acknowledge_approval` for the JX-only
approval acknowledgment action.

`dry-run` reloads the planned action, rechecks the approval and the action
kind's policy, and prints the "would do" text. Rerun actions also recheck the
latest stored workspace snapshot. It does not call DevIDE or execute a command.

`execute` also reloads and rechecks the action. Without `--confirm`, it refuses
and prints dry-run guidance. With `--confirm`, it calls only:

```text
POST /api/workspaces/:id/runs
```

The body is only:

```json
{"command_id":"compile|test|format|precommit"}
```

On DevIDE rerun success, JX records the action as executed, stores the DevIDE
run result in the ledger, and acknowledges the related approval item.

On approval acknowledgment success, JX records the action as executed and stores
the acknowledged approval status. No DevIDE request is made.

`show` displays the action and its immutable event trail. `history` displays all
safe-action events for an approval.

## Leases

Approvals and safe actions can be claimed before execution:

```bash
jx leases acquire approval <approval-id> --owner <owner>
jx leases acquire action <action-id> --owner <owner>
jx leases release <lease-id> --owner <owner>
jx leases reassign approval|action|workspace <id> --owner <owner>
```

An active lease held by a different owner denies proposal, dry-run, and execute
before any DevIDE mutation. Expired leases are marked stale and appear in
`jx queue ls`. If an operator acquires an approval lease before proposing a
safe action, the lease correlation ID is reused for the proposed action and
continues through execution audit events, DevIDE request/response recording,
and the approval acknowledgment attempt.

## Delegated Execution

Delegated execution lets durable JX agents claim and execute existing safe
actions. It does not create a new execution surface. Agents cannot introduce
commands, shell argv, generic HTTP requests, proposal application, file writes,
or agent prompts. The only DevIDE mutation remains the safe-action path for
`rerun_devide_command`:

```text
assignment -> action-id -> JX.SafeActions.execute/2 -> POST /api/workspaces/:id/runs
```

Agent commands:

```bash
jx agents register <agent-id> --capability safe_action:rerun_devide_command --workspace <workspace-id>
jx agents heartbeat <agent-id>
jx agents ls --status idle|busy|stale|disabled|all
```

Assignment commands:

```bash
jx assignments create <action-id>
jx assignments ls --status active
jx assignments claim <assignment-id> --agent <agent-id>
jx assignments start <assignment-id> --agent <agent-id>
jx assignments progress <assignment-id> --agent <agent-id> --summary "checked evidence"
jx assignments execute <assignment-id> --agent <agent-id> --confirm
jx assignments fail <assignment-id> --agent <agent-id> --summary "reason"
jx assignments expire
```

Assignment lifecycle events are append-only:

- `assignment.created`
- `assignment.claimed`
- `assignment.started`
- `assignment.progressed`
- `assignment.completed`
- `assignment.failed`
- `assignment.expired`

Agents also emit `agent.registered` and `agent.heartbeat` evidence. Assignment
reports are deduplicated by fingerprint so reconnects or repeated reports do
not spam the evidence plane.

Claiming an assignment acquires the existing action lease for the agent. A
second agent cannot claim the same assignment while that lease is active. The
agent must be live, must advertise `safe_action:<kind>`, and must match the
workspace affinity when one is configured. Expired assignments and stale agents
are surfaced in `jx queue ls`; use `jx assignments expire` to release stale
claims, then create a replacement assignment from the still-planned action if
the work remains valid.

Operator lifecycle:

```bash
jx queue ls --sort urgency
jx approvals show <approval-id>
jx actions propose <approval-id>
jx actions dry-run <action-id>
jx assignments create <action-id>
jx agents ls --status idle
jx assignments claim <assignment-id> --agent <agent-id>
jx assignments start <assignment-id> --agent <agent-id>
jx assignments execute <assignment-id> --agent <agent-id> --confirm
jx timeline assignment <assignment-id>
jx timeline action <action-id>
```

If execution fails after the assignment starts, the assignment moves to
`failed`, its action lease is released, and the action's safe-action audit
events say whether to retry the same action, repropose from fresh evidence, or
inspect DevIDE. Already completed assignments and already executed safe actions
are non-replayable.

## Remote Runner Sessions

Remote runners make delegated execution durable across hosts and tmux sessions.
They do not add a new execution path. A runner is a host/session identity that
maps to a normal delegated agent identity, then claims an existing assignment
and executes only through that assignment's stored action ID.

The execution path remains:

```text
runner session -> assignment -> action-id -> JX.SafeActions.execute/2 -> POST /api/workspaces/:id/runs
```

There is still no arbitrary argv execution, shell forwarding, generic HTTP
proxying, proposal apply, file write, or agent prompt execution.

Runner commands:

```bash
jx runners register <runner-id> \
  --agent <agent-id> \
  --host <host> \
  --capability safe_action:rerun_devide_command \
  --workspace <workspace-id> \
  --tmux-server jx \
  --tmux-session-prefix jx-<runner-id>

jx runners heartbeat <runner-id> [--session <session-id>]
jx runners ls --status idle|busy|stale|disabled|all
jx runners show <runner-id>
```

Session commands:

```bash
jx assignments claim <assignment-id> --runner <runner-id> \
  --session <session-id> \
  --tmux-session <tmux-session-name> \
  --log-path <path>

jx sessions ls --status active
jx sessions show <session-id>
jx sessions logs <session-id>
jx sessions attach <session-id>
jx sessions expire
```

`sessions logs` returns stored log metadata only. It does not read a remote file.
`sessions attach` prints an explicit tmux attach command for the operator. JX
does not execute tmux as part of the safe-action lane.

Runner/session evidence is append-only:

- `runner.registered`
- `runner.heartbeat`
- `runner_session.created`
- `runner_session.reconnected`
- `runner_session.claimed`
- `runner_session.started`
- `runner_session.heartbeat`
- `runner_session.progressed`
- `runner_session.completed`
- `runner_session.failed`
- `runner_session.expired`
- `runner_session.logs`
- `runner_session.attach`

Exactly one active runner session can own an assignment. The active session key
is released only when the session completes, fails, ends, or expires. If a
runner misses heartbeats beyond its TTL, `jx sessions expire` marks the runner
session and assignment expired, releases the action lease, and lets an operator
create a replacement assignment from the still-planned action.

Remote-runner operator lifecycle:

```bash
jx queue ls --sort urgency
jx approvals show <approval-id>
jx actions propose <approval-id>
jx actions dry-run <action-id>
jx assignments create <action-id>
jx runners ls --status idle
jx runners register <runner-id> --agent <agent-id> --capability safe_action:rerun_devide_command --workspace <workspace-id>
jx assignments claim <assignment-id> --runner <runner-id>
jx sessions show <session-id>
jx sessions logs <session-id>
jx sessions attach <session-id>
jx timeline session <session-id>
jx timeline runner <runner-id>
jx timeline assignment <assignment-id>
```

Incident recovery:

- If a runner is stale, run `jx sessions expire`, then inspect
  `jx timeline session <session-id>` and `jx timeline assignment <assignment-id>`.
- If the assignment is still valid, create a replacement assignment from the
  safe action and claim it with a live runner.
- If the DevIDE run already succeeded but approval acknowledgment failed, follow
  the action history guidance from `jx actions show <action-id>` before
  reproposing. The runner session is evidence, not a replay token.

## Diagnostics And Recovery

Use `jx events check` for a read-only health check of the operational evidence
plane. It reports corrupt event payloads, unknown/future event versions, missing
correlation IDs, stale active leases, duplicate active leases, and lease key
mismatches. It does not add execution authority and does not mutate DevIDE.

Recovery rules:

- Corrupt event: preserve the event ID, inspect the relevant timeline, refresh
  DevIDE state if needed, and rebuild queue state with `jx queue rebuild`.
- Stale lease: release it if you own it; otherwise reassign explicitly before
  proposing or executing.
- Interrupted execution: use `jx actions show <action-id>` and
  `jx timeline action <action-id>` to identify whether the operator should
  retry, repropose, or inspect DevIDE. Already executed actions remain
  non-replayable.

## Audit Events

Safe actions emit append-only events for:

- `proposed`
- `dry_run_viewed`
- `execute_attempted`
- `execute_denied`
- `executed`
- `approval_ack_attempted`
- `approval_acknowledged`

Execution persists the DevIDE response envelope, including HTTP status and
decoded response body, so later review can distinguish JX policy decisions from
DevIDE run outcomes.

Execution outcomes are explicit:

- `success` means DevIDE returned a well-formed run response.
- `devide_failure` means DevIDE returned an HTTP error such as 401, 403, 409,
  or 503. Inspect DevIDE and retry the same action only after the DevIDE-side
  condition is resolved.
- `network_failure` means JX could not complete the POST. Retry the same action
  after connectivity or configuration is fixed.
- `policy_denied` means JX denied the action before any DevIDE POST. Refresh
  DevIDE state and repropose from current approval evidence if the action is
  still needed.
- `malformed_response` means DevIDE returned 2xx but the run envelope was not
  usable. Inspect DevIDE before retrying; repropose from fresh evidence if the
  action is stale.
- `approval_ack_failure` means DevIDE accepted the rerun and JX recorded the
  action as executed, but JX could not acknowledge the approval.
  For `acknowledge_approval`, it means JX could not update the approval item;
  the action remains planned and can be retried after local state storage is
  healthy.

## Retry And Reproposal

`jx actions show <action-id>` prints the current status, immutable events,
correlation ID, outcome, and a `next:` line. The same action may be retried only
when the action is still planned and the latest outcome says retry is safe, such
as `network_failure` or a resolved `devide_failure`.

Already executed actions are non-replayable. Expired, revoked, and
approval-mismatched actions are denied before any effect. Unsafe-isolation and
missing-snapshot rerun actions are denied before any DevIDE POST. For those,
refresh DevIDE state and create a new approval/action proposal from current
evidence instead of forcing the old action.

## Incident Note

If the run succeeded but approval acknowledgment failed, do not execute the
action again. Use the `correlation_id` from `jx actions show <action-id>` to
inspect the DevIDE run/status/audit, then acknowledge or dismiss the approval
manually once the operator has reconciled the state. Repropose only if new
DevIDE evidence creates a new approval.

## Boundary

JX does not run shell commands, build argv, write files, apply proposals, prompt
agents, or call arbitrary DevIDE mutation endpoints. DevIDE remains responsible
for bearer auth, policy gating, command allowlist resolution, command history,
and audit events.

## Release Readiness

Safe actions are release-ready only while these invariants stay true:

- `JX.SafeActions.Registry` lists exactly `rerun_devide_command` and
  `acknowledge_approval`; adding a kind requires explicit contract-test updates.
- DevIDE reruns use only `POST /api/workspaces/:id/runs` with a stored
  allowlisted `command_id`; JX never builds arbitrary argv or shells out.
- `safe_action_events` remains append-only and carries the action
  `correlation_id` across proposal, dry-run, execute attempt, DevIDE response,
  and approval acknowledgment events.
- Executed, expired, revoked, approval-mismatched, unsafe-isolation, and
  missing-snapshot actions are denied before any DevIDE side effect.

Operator commands for release verification:

```bash
jx actions show <action-id>
jx actions history <approval-id>
jx actions propose <approval-id> [--kind rerun_devide_command|acknowledge_approval] [--owner <owner>]
jx actions dry-run <action-id> [--owner <owner>]
jx actions execute <action-id> --confirm [--owner <owner>]
```

Failure modes must remain operator-visible through `jx actions show` and
`jx actions history`: `devide_failure`, `network_failure`, `policy_denied`,
`malformed_response`, `approval_ack_failure`, `confirmation_required`, and
`replay_denied`.

Validation commands before release:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix jx.contract
mix test
mix precommit
mix escript.build
./jx help actions
```
