# DevIDE Adapter

`jx devide` consumes DevIDE's workspace API and turns per-workspace state into
portfolio and risk summaries. The adapter talks to DevIDE only over HTTP.

Portfolio, status, risks, and watch commands are read-only against DevIDE. The
only DevIDE write endpoint in this integration is the M30 approval-gated safe
action endpoint for rerunning an allowlisted DevIDE command. JX-only approval
acknowledgment updates local JX state and does not call DevIDE.

## Configuration

`JX_DEVIDE_URL`

Base URL for DevIDE. Defaults to `http://localhost:4000`.

`JX_DEVIDE_API_TOKEN`

Bearer token for the DevIDE API. This must match DevIDE's `DEV_IDE_API_TOKEN`
or `:dev_ide, :api_token` value. The CLI does not print this value.

`JX_NOTIFICATION_FILE`

Optional JSONL sink for approval attention events. Relative paths are written
under the JX state directory; absolute paths must also resolve inside that
directory. Each event is redacted before it reaches the sink.

`JX_STATE_DIR`

Optional state directory for file sinks and runtime artifacts. If unset, the
file sink uses the configured `JX_DB` directory, or `~/.jx`.

## Commands

```bash
jx devide workspaces
jx devide status <workspace-id>
jx devide portfolio
jx devide risks
jx devide watch --interval-ms 5000
jx devide watch --state --interval-ms 5000
jx portfolio summary
jx approvals ls
jx approvals show <id>
jx approvals ack <id>
jx approvals dismiss <id>
jx queue ls --sort urgency
jx queue workspace <workspace-id>
jx leases ls --status active
jx leases acquire approval|action|workspace <id> --owner <owner>
jx leases release <lease-id> --owner <owner>
jx timeline workspace|approval|action <id>
jx actions show <action-id>
jx actions history <approval-id>
jx actions propose <approval-id> [--kind rerun_devide_command|acknowledge_approval] [--owner <owner>]
jx actions dry-run <action-id> [--owner <owner>]
jx actions execute <action-id> --confirm [--owner <owner>]
```

## Operational Control Plane v1

JX keeps DevIDE observation as one input to a fleet-level operator control
plane. The control-plane surfaces are:

- `jx queue ls` for blocked, stale, risky, and awaiting-operator work across
  workspaces, approvals, actions, and leases.
- `jx queue workspace <workspace-id>` for workspace health, evidence freshness,
  related approvals/actions, and current lease ownership.
- `jx leases acquire|release|reassign` for explicit operator claims.
- `jx timeline workspace|approval|action <id>` for append-only reconstruction.
- `jx actions show/history` for safe-action accountability and recovery
  guidance.

Queue views can be filtered and sorted by urgency, freshness, owner, and risk:

```bash
jx queue ls --risk blocked --sort urgency
jx queue ls --owner alice --freshness stale
jx queue ls --kind approval --workspace ws-1
```

Leases prevent conflicting operators from executing the same approval or action
from different sessions:

```bash
jx leases acquire approval <approval-id> --owner alice --ttl-seconds 900
jx actions propose <approval-id> --owner alice
jx leases acquire action <action-id> --owner alice
jx actions dry-run <action-id> --owner alice
jx actions execute <action-id> --confirm --owner alice
jx leases release <lease-id> --owner alice
```

If another owner holds an active lease, propose/dry-run/execute are denied
before any DevIDE POST. Expired leases become stale queue items and can be
reassigned explicitly.

The operational evidence plane is append-only. DevIDE snapshots, approval
events, safe-action events, portfolio risks, leases, and operator decisions are
normalized into `operational_events`; reducers rebuild current queue state and
timelines from that event stream. Correlation IDs are copied from active leases
into proposed safe actions when the operator claims an approval first, and the
same action correlation is then carried through the DevIDE request, stored run
result, safe-action audit events, and approval acknowledgment attempt.

Use `jx events check` when the fleet view looks inconsistent or after a crash:

```bash
jx events check
jx queue rebuild
jx timeline approval <approval-id>
jx timeline action <action-id>
```

`events check` is read-only. It reports corrupt JSON payloads, unknown/future
event versions, missing correlation IDs, stale active leases, active-key
mismatches, and duplicate active leases. It does not repair or delete events.

## Operator Workflow v1

The happy path starts with DevIDE observation and ends with an audited action or
local acknowledgment:

```bash
# Refresh DevIDE snapshots and create deduplicated approval items.
jx devide watch --state --interval-ms 5000

# Find approvals needing attention.
jx approvals ls --source devide

# Inspect the self-contained evidence bundle and snapshot freshness.
jx approvals show <approval-id>

# Claim the work so another operator does not execute the same item.
jx leases acquire approval <approval-id> --owner alice

# For a failed allowlisted command on a safe DB snapshot, propose a rerun.
jx actions propose <approval-id> --owner alice

# For a proposal conflict, unsafe DB, or policy block, propose local
# acknowledgment instead of DevIDE mutation.
jx actions propose <approval-id> --owner alice --kind acknowledge_approval

# Review the stored action before any effect.
jx actions dry-run <action-id> --owner alice

# Execute only after explicit confirmation.
jx actions execute <action-id> --confirm --owner alice

# Audit the immutable event trail afterward.
jx actions show <action-id>
jx actions history <approval-id>
jx timeline approval <approval-id>
```

The CLI surfaces this loop in each view: `jx devide status` and
`jx devide risks` point to the approval queue, `jx approvals ls/show` point to
safe-action proposal commands, and `jx actions show/history` point back to the
approval and DevIDE evidence. Operators should check the evidence source and
`last_observed_at` timestamp in `jx approvals show` before executing a rerun.

If the evidence is stale, refresh snapshots with `jx devide watch --state` and
reinspect the approval before proposing or executing an action.

`watch` establishes an initial baseline, suppresses unchanged polls, and emits
later changes. It highlights new `blocked` and `needs_review` states, including
conflict proposals, failed or timed-out runs, recent policy blocks, and
unsafe/shared database isolation.

With `--state`, `watch` also writes the latest DevIDE workspace snapshots into
JX's durable state. New `blocked` or `needs_review` transitions become JX
monitor events and unread notifications; identical repeated snapshots do not
create duplicate events. `jx portfolio summary` includes the last stored DevIDE
workspace state alongside local session portfolio data.

Stateful DevIDE ingestion also creates JX approval items for operator review:

- `proposal_conflict` for conflict, overlap, or invalid proposal risk
- `unsafe_db` for unsafe or shared-stage database isolation
- `failed_run` for failed or timed-out command runs
- `policy_blocked` for recent DevIDE policy blocks

Approvals are deduplicated by source, workspace, kind, and target. `ack` marks
an item seen while keeping it active; `dismiss` closes it. There is no
approve-to-mutate path in this adapter.

Approval notifications are routed through sink modules. The default sink writes
operator-visible Logger output. Set `JX_NOTIFICATION_FILE=notifications.jsonl`
to append redacted JSONL under the JX state directory:

```bash
JX_NOTIFICATION_FILE=notifications.jsonl jx devide watch --state --interval-ms 5000
```

New approval items emit one sink event. Deduped duplicates do not emit again,
severity escalations emit an update, and repeated failed-run evidence emits a
repeated-failure event. Notification sinks do not call DevIDE, mutate
workspaces, or add approval/apply/run authority.

Safe action proposals support exactly two action kinds:
`rerun_devide_command` and `acknowledge_approval`. `rerun_devide_command` is
available only for allowlisted DevIDE commands (`compile`, `test`, `format`,
`precommit`) and only when the latest stored workspace snapshot has local,
ephemeral, or unknown DB isolation. `acknowledge_approval` updates only the JX
approval queue and never calls DevIDE.

## Runner execution protocol v1

JX can delegate a planned safe action into DevIDE's durable runner protocol
without adding a new DevIDE mutation route. It uses the existing
`POST /api/workspaces/:id/runs` endpoint with
`"execution_protocol": "jx.runner.v1"` and the approved `command_id`. The
request also carries the JX assignment id, action id, safe-action kind, and
`x-jx-correlation-id`. It never carries shell strings or argv. DevIDE resolves
the command through its own `DevIDE.Runners.SafeAction` registry and returns a
queued assignment for real runners to poll.

Lifecycle:

1. JX proposes and approves a `rerun_devide_command` safe action.
2. `JX.DelegatedExecution.create_assignment/2` creates a JX delegated
   assignment with the action correlation id.
3. `JX.DelegatedExecution.enqueue_devide_runner_assignment/2` asks DevIDE to
   enqueue a runner assignment through the existing run endpoint. Optional
   runner requirements such as host, OS, tools, repo, branch isolation, and
   concurrency limit are routing hints only.
4. A runner polls DevIDE `POST /api/runner/v1/assignments/poll`, claims exactly
   one compatible assignment, executes only the returned safe action, and
   reports progress with its claim token.
5. The runner completes or fails with evidence. DevIDE replay keeps the
   assignment and append-only reports available at
   `GET /api/runner/v1/assignments/:id`.
6. JX reconciles that replay with
   `JX.DelegatedExecution.reconcile_devide_runner_assignment/2`, recording
   idempotent operational events on the JX assignment timeline.

Correlation is copied through every hop: JX safe action, JX delegated
assignment, DevIDE enqueue metadata, DevIDE runner reports, DevIDE replay, and
JX operational events. Duplicate DevIDE reports and duplicate JX reconciliations
are idempotent by deterministic report/event ids.

The DevIDE assignment state machine is:

```text
queued -> claimed -> running -> succeeded | failed | expired | abandoned
```

Invalid transitions, stale claim tokens, expired leases, conflicting duplicate
report ids, and duplicate terminal submissions are rejected by DevIDE. Exact
duplicate report ids return the original report so runners can retry network
submissions safely.

Failure classes are normalized across the protocol: `enqueue_failed`,
`claim_rejected`, `lease_expired`, `report_rejected`, `action_failed`,
`replay_mismatch`, and `runner_lost`. JX stores the class in operational events
and projections; DevIDE returns it in runner protocol error envelopes and
terminal replay evidence.

`JX.DevIDE.RunnerReconciler` can run repeatedly to fetch DevIDE replay for
enqueued assignments and repair missed reports. It records events through
deterministic ids, so repeated reconciliation does not duplicate reports or
re-execute actions.

Reducer-backed projections are rebuilt from append-only events for assignment
state, runner fleet state, queue state, workspace state, and failure summaries.
The append-only event log remains the source of truth.

Capability-aware routing never expands executable authority. JX and DevIDE can
match by workspace, host, OS, tools, repo, branch isolation, and runner
concurrency limit, but command authorization still comes only from the
safe-action registries.

## Workspace runtime orchestration v1

JX runtime environments are durable placement records for isolated worktrees.
They let an operator provision reusable workspace runtimes, route approved
safe-action assignments to those runtimes, and replay lifecycle evidence without
changing what DevIDE can execute.

Runtime lifecycle:

```text
planned -> provisioning -> ready -> assigned -> released
                                -> failed | expired
```

Commands:

- `jx runtimes provision <action-id> --project <project>` creates or reuses a
  deterministic runtime record for an approved safe action, builds a constrained
  worktree provisioning script, runs it through the existing host adapter, and
  records `runtime.planned`, `runtime.provisioning`, and `runtime.ready` events.
- `jx runtimes assign <runtime-id> <action-id> [--runner <runner-id>]` creates
  a delegated assignment with runtime placement requirements. If a runner is
  supplied, JX claims a runner session for that runtime; it still does not
  execute the safe action.
- `jx runtimes ls|show|release` are lifecycle and inspection commands only.

Runtime routing metadata includes host, OS, repo, tools, branch isolation,
runtime id, and runtime path. These fields affect placement only. They are
copied into the DevIDE runner assignment as `runner_requirements`/`metadata`
and into runner poll claims for matching, but DevIDE still resolves the
safe-action id through `DevIDE.Runners.SafeAction`. No JX runtime field can
become argv, shell, an executable payload, or a generic HTTP proxy target.

Recovery semantics:

1. Runtime lifecycle events are append-only operational events with entity type
   `runtime_environment`.
2. Reducers rebuild runtime projections together with queue, runner, assignment,
   workspace, and failure projections.
3. Expired runtimes are visible through `jx runtimes ls --status expired`,
   `jx dashboard`, and runtime timelines.
4. Failed provisioning records the failure without creating an executable
   assignment. Re-run provisioning after fixing host/worktree state; do not
   bypass DevIDE safe-action authorization.

Partial failures are visible on both sides. DevIDE replay contains terminal
evidence such as exit codes and output digests; JX records
`devide_runner.assignment_failed` and `devide_runner.report_reconciled` events
on the assignment/action timeline so operators can inspect the failure without
re-executing the safe action.

## Operator dashboard v1

`jx dashboard` is the read-only operator visibility layer for the JX/DevIDE
event plane. It does not claim leases, acknowledge approvals, enqueue work,
proxy DevIDE endpoints, or execute safe actions. It renders existing JX
read-models and reducer-backed projections so operators can see the system
without expanding authority.

Dashboard surfaces:

- `jx dashboard` summarizes queue state, runner fleet state, active and stale
  leases, assignment lifecycle, workspace health, failed/expired work,
  replay/reconciliation status, failure summaries, and recent operational
  events.
- `jx dashboard workspace <workspace-id>` drills into one workspace's health,
  approvals, safe actions, assignments, runner sessions, leases, and timeline.
- `jx dashboard runner <runner-id>` shows runner identity, sessions,
  assignments, heartbeats/reports, and runner timeline.
- `jx dashboard assignment <assignment-id>` follows the claim, progress,
  runner reports, replay state, and failure chain for one assignment.
- `jx dashboard action <action-id>` connects the safe action back to approval
  evidence, audit events, assignments, reconciliation, and timeline evidence.

Statuses mean:

- `queued` or `created`: work exists but has not been claimed by a runner or
  delegated agent.
- `claimed`: a live runner or agent holds the assignment/lease.
- `running` or `started`: execution has crossed the DevIDE runner boundary.
- `progressed`: evidence has been reported but the assignment is not terminal.
- `succeeded` or `completed`: terminal success.
- `failed`: terminal failure with report or replay evidence.
- `expired`: lease/session/assignment TTL elapsed and the work must be
  reconsidered from current evidence.
- `abandoned`: DevIDE considers the runner gone before a clean terminal report.
- `stale`: JX has not seen a timely heartbeat or workspace observation.

Projection lifecycle:

1. Operational events are appended as evidence from observations, approvals,
   safe actions, leases, assignments, runner reports, and DevIDE replay.
2. `JX.OperationalEvents.Reducer` rebuilds deterministic assignment, runner
   fleet, queue, workspace, and failure-summary projections from those events.
3. The dashboard combines those projections with existing durable JX tables for
   drill-down detail. Unknown future event kinds are tolerated and should not
   crash projection rebuilds.
4. Reconciliation can be run repeatedly. Deterministic report and event IDs
   prevent duplicate reports or duplicated actions.

Recovery flow:

- Stale leases: open `jx dashboard` or `jx leases ls --stale --status all`,
  inspect owner/resource, then release your own lease or reassign explicitly.
- Failed assignments: open `jx dashboard assignment <assignment-id>`, inspect
  runner reports and replay failure class, then refresh evidence or create a new
  assignment from the existing safe action only after the cause is understood.
- Replay mismatches: inspect `jx timeline assignment <assignment-id>` and the
  dashboard replay section. Do not force execution; fix the correlation,
  workspace, action, or protocol evidence mismatch and reconcile again.
- Dead runners: open `jx dashboard runner <runner-id>`, inspect heartbeat and
  session expiry. Expired sessions should surface in queue/dashboard state and
  can be reassigned through existing lease/assignment flows.

Those two kinds are registered through `JX.SafeActions.Registry`; each kind owns
its proposal policy, execution path, audit payload, and recovery guidance.

`jx actions dry-run <action-id>` prints what would happen without calling
DevIDE. `jx actions execute <action-id> --confirm` rechecks the same policy and
lease ownership. A rerun then calls only DevIDE's narrow run endpoint; an
acknowledgment only marks the approval acknowledged in JX. Execution is
idempotent by action id: already executed, expired, revoked, approval-mismatched,
unsafe-isolation, missing-snapshot, and lease-conflicted actions are denied and
audited without another DevIDE call. Use `jx actions show <action-id>` for
retry/reproposal guidance. Network failures can be retried after connectivity
is fixed; policy denials and stale evidence require refreshing DevIDE state and
reproposing. If DevIDE accepts the run but approval acknowledgment fails,
inspect DevIDE with the action `correlation_id` and manually ack/dismiss the
approval instead of retrying the action.

## Recovery Procedures

For corrupt operational events:

1. Run `jx events check --json` and preserve the output with the event IDs.
2. Use `jx timeline workspace|approval|action <id>` around the affected entity
   to inspect the surrounding valid events.
3. Refresh DevIDE evidence with `jx devide watch --state` if the corrupt event
   came from observation.
4. Rebuild the read model with `jx queue rebuild`; reducers skip unknown entity
   types and degrade corrupt payloads to empty evidence rather than executing
   anything.
5. Do not delete append-only events without an explicit maintenance plan.

For stale leases:

1. Run `jx leases ls --stale --status all` or `jx queue ls --kind lease`.
2. If you own the lease, release it with `jx leases release <lease-id> --owner <owner>`.
3. If ownership is stale or the operator is gone, reassign explicitly with
   `jx leases reassign approval|action|workspace <id> --owner <owner>`.
4. Re-run `jx events check` and `jx queue ls --owner <owner>` before executing.

For interrupted executions:

1. Inspect `jx actions show <action-id>` and `jx timeline action <action-id>`.
2. If the latest outcome is `network_failure`, retry only after confirming the
   action is still planned and DevIDE connectivity is healthy.
3. If the latest outcome is `devide_failure`, inspect DevIDE status/audit first.
4. If the latest outcome is `malformed_response`, inspect DevIDE for a possible
   started run before reproposing.
5. If DevIDE accepted the run but approval acknowledgment failed, do not retry
   the action. Acknowledge or dismiss the approval manually after reconciling
   the DevIDE run by correlation ID.

## Contract

The primary coupling is the DevIDE M19 HTTP API:

- `GET /api/workspaces`
- `GET /api/workspaces/:id/status`
- `GET /api/workspaces/:id/runs`
- `GET /api/workspaces/:id/proposals`
- `GET /api/workspaces/:id/audit`

M30 adds one constrained action endpoint:

- `POST /api/workspaces/:id/runs` with `{ "command_id": "compile" | "test" | "format" | "precommit" }`

Stateful ingestion still reads DevIDE over the M19 endpoints and writes only to
JX's own database. Action execution never constructs argv and never calls any
DevIDE endpoint other than the run endpoint above.

Run fixture-backed contract checks with:

```bash
mix jx.contract
```
