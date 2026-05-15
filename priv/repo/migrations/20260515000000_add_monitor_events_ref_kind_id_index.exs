defmodule JX.Repo.Migrations.AddMonitorEventsRefKindIdIndex do
  use Ecto.Migration

  # Backs the batched "latest fingerprint per (ref, kind)" lookup that
  # replaces the per-event SELECT in JX.MonitorEvents.insert_new_events/1.
  # Purely additive — no UNIQUE constraint (would silently break the
  # state-change-log semantic; see docs/perf/monitor_events_dedup_scope.md).
  def change do
    create(index(:monitor_events, [:ref, :kind, :id]))
  end
end
