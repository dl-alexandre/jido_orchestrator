# #3 — `monitor_events` deduplication: scope for next session

Surfaced during `/phx:perf` (see commit `3e4124a`). The original agent
recommendation — make `(ref, kind, fingerprint)` UNIQUE and use
`insert_all(on_conflict: :nothing)` — was **rejected** because it would
silently break the table's intended semantics. This doc captures the
corrected scope so a fresh session can pick up without re-doing the
investigation.

---

## The semantic mismatch

From `lib/jx/monitor_events.ex:339` — `duplicate_latest?/1` rejects a
candidate event only if its fingerprint matches the **most recently
inserted** row for that `(ref, kind)`, not any prior row:

```elixir
Event
|> where([event], event.ref == ^ref and event.kind == ^kind)
|> order_by([event], desc: event.id)
|> limit(1)
|> Repo.one()
|> case do
  %Event{fingerprint: ^fingerprint} -> true   # reject
  _event -> false                              # keep
end
```

That makes the table a **state-change log**. A fingerprint can
legitimately reappear if state went `X → Y → X`:

| event | ref | kind | fp | inserted? |
|-------|-----|------|----|----------:|
| 1 | task-1 | session | X | ✅ |
| 2 | task-1 | session | X | ❌ matches latest |
| 3 | task-1 | session | Y | ✅ state changed |
| 4 | task-1 | session | X | ✅ state changed back |

A `UNIQUE(ref, kind, fingerprint)` constraint would silently drop
row 4 — quiet correctness regression.

## Revised scope

The N-pre-SELECT problem is real. The right fix is to **batch the
lookup**, not change the constraint.

1. **Batched lookup function** — replace `Enum.reject(&duplicate_latest?/1)`
   with a single `fetch_latest_fingerprints_for/1` query returning
   `%{{ref, kind} => fingerprint}` for the latest event of each
   distinct `(ref, kind)` in the candidate batch. Filter in Elixir.
   `N queries → 1 query`. `record_event/1` (single-element batches) is
   handled by the same path with no special case.

2. **Migration — purely additive** — add `index(:monitor_events,
   [:ref, :kind, :id])` so the latest-per-`(ref, kind)` lookup is an
   index seek instead of a partition scan. No `UNIQUE`, no data
   manipulation, no rollback risk.

3. **Decide on batch-internal dedupe** — the current code has an
   implicit gap: if two events with identical `(ref, kind, fingerprint)`
   arrive in the same batch and no prior DB row exists for that pair,
   both insert. Explicit choice required:
   - **Preserve** — match current behavior exactly (recommend if any
     downstream consumer relies on it; needs verification).
   - **Collapse** — drop in-batch duplicates against the latest *kept*
     event for that `(ref, kind)`, which is the more correct
     interpretation of "no consecutive duplicates."

4. **Query-shape pick** — three candidates for `fetch_latest_fingerprints_for/1`:
   - Window function: `ROW_NUMBER() OVER (PARTITION BY ref, kind ORDER BY id DESC)`
     filtered to `rn = 1`
   - Correlated subquery: `WHERE id = (SELECT MAX(id) FROM monitor_events
     WHERE ref = ... AND kind = ...)`
   - GROUP BY + JOIN: `SELECT MAX(id) ... GROUP BY ref, kind` then join
     back for fingerprint

   Given the call profile (see below), `U ≈ N` per batch — most candidates
   have a unique `(ref, kind)`. GROUP BY + JOIN is the simplest and likely
   sufficient; check `EXPLAIN QUERY PLAN` before committing.

5. **Tests to write before code**:
   - `X → Y → X` reversion case (locks the semantic in regression
     coverage)
   - Batch-internal duplicate handling (whichever option from step 3)
   - Query-count assertion: N events with U unique `(ref, kind)` →
     1 query, not N (use `Ecto.Adapters.SQL.Sandbox` query counter or
     `:telemetry`)

## Call profile (answered)

### `record_scan/1` — the batched path that matters

- **Caller**: `lib/jx/workspace.ex:2063`, in the monitor scan flow.
- **Driven by**: `JX.Jido.Sensors.MonitorScan`, scheduled via
  `JX.OrchestratorMonitorSensor`.
- **Frequency**: `config/config.exs:28-31` defaults to
  `interval_ms: 30_000` with `enabled: false`. Deployments override
  to enable. Every ~30 s when on.
- **Batch shape** — `scan_events/1` concatenates events from up to 8
  input streams per scan:
  - 1 queue snapshot event (always)
  - N per session profile (`Enum.flat_map(profiles, &profile_events/1)`)
  - N per watch update
  - N per ci_watch update
  - 1 per daemon_health_alert
  - 1 per call_handoff (`limit: 100` upstream)
  - 1 per delegation (`Enum.filter` over `Delegations.list(limit: 500)`)
  - 1 per delegation_review (`limit: 100` upstream)
- **Realistic sizes**: small cluster ~5–20; loaded cluster easily
  100–300 (the `limit: 500` delegations source is uncapped after
  filtering). This is where the N pre-SELECTs hurt.

### `record_event/1` — the one-off path (perf-irrelevant)

- **Callers**: `lib/jx/workspace.ex:828` (external "wake" event from
  CLI), `lib/jx/dev_ide/state.ex:212` (DevIDE state changes).
- **Always batch size 1.** At most one SELECT per call regardless.
- No special case needed in the new code path.

### Return-shape constraint

`record_scan/1`'s caller does:

```elixir
case MonitorEvents.record_scan(...) do
  {:ok, events} -> Notifications.record_events(events)
end
```

The batched version **must return the same shape** — a list of
inserted `%Event{}` structs. `Repo.insert_all(SessionObservation,
maps, returning: true)` provides this on ecto_sqlite3.

## Open questions still wanting fresh attention

1. Step 3 — preserve or collapse batch-internal duplicates? Grep
   downstream consumers (`Notifications.record_events/1` and any
   signal dispatch) before committing.
2. Step 4 — pick the query shape; verify with `EXPLAIN QUERY PLAN`
   on a representative DB.
3. Whether to bundle this with the deferred Ecto perf finding #14
   (`OperationalEvents.record_many` → `insert_all`) since both touch
   high-frequency monitor/event paths.

## Related

- `/phx:perf` original finding set in commit message `3e4124a`.
- Deferred companion: finding #14 (`OperationalEvents.record_many`
  batched insert).
- Composite index style precedent: `priv/repo/migrations/
  20260425032000_create_session_observations.exs` (also indexed on
  `:inserted_at` alone — same anti-pattern, separate work item).
