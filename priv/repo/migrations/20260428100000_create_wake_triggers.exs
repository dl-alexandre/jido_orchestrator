defmodule JX.Repo.Migrations.CreateWakeTriggers do
  use Ecto.Migration

  def change do
    create table(:wake_triggers) do
      add :trigger_id, :text, null: false
      add :name, :text, null: false, default: ""
      add :status, :text, null: false, default: "active"
      add :message, :text, null: false
      add :project, :text, null: false, default: ""
      add :ref, :text, null: false, default: ""
      add :severity, :text, null: false, default: "warning"
      add :schedule, :text, null: false, default: "once"
      add :every_seconds, :integer
      add :next_run_at, :utc_datetime_usec
      add :last_run_at, :utc_datetime_usec
      add :run_count, :integer, null: false, default: 0
      add :last_result, :text, null: false, default: ""

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:wake_triggers, [:trigger_id])
    create index(:wake_triggers, [:status, :next_run_at])
    create index(:wake_triggers, [:project])
    create index(:wake_triggers, [:ref])
    create index(:wake_triggers, [:updated_at])
  end
end
