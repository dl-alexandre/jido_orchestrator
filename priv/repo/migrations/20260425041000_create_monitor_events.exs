defmodule JX.Repo.Migrations.CreateMonitorEvents do
  use Ecto.Migration

  def change do
    create table(:monitor_events) do
      add :event_id, :text, null: false
      add :kind, :text, null: false
      add :severity, :text, null: false
      add :ref, :text, null: false, default: ""
      add :project, :text, null: false, default: ""
      add :session_type, :text, null: false, default: ""
      add :session_kind, :text, null: false, default: ""
      add :control_mode, :text, null: false, default: ""
      add :work_state, :text, null: false, default: ""
      add :action, :text, null: false, default: ""
      add :summary, :text, null: false, default: ""
      add :fingerprint, :text, null: false
      add :payload, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:monitor_events, [:event_id])
    create index(:monitor_events, [:kind])
    create index(:monitor_events, [:severity])
    create index(:monitor_events, [:ref])
    create index(:monitor_events, [:inserted_at])
    create index(:monitor_events, [:ref, :kind, :fingerprint])
  end
end
