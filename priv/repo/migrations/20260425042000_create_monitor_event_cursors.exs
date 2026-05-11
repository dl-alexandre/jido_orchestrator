defmodule JX.Repo.Migrations.CreateMonitorEventCursors do
  use Ecto.Migration

  def change do
    create table(:monitor_event_cursors) do
      add :consumer, :text, null: false
      add :last_event_id, :integer, null: false, default: 0
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:monitor_event_cursors, [:consumer])
    create index(:monitor_event_cursors, [:last_event_id])
  end
end
