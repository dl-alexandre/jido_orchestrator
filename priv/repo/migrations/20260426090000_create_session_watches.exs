defmodule JX.Repo.Migrations.CreateSessionWatches do
  use Ecto.Migration

  def change do
    create table(:session_watches) do
      add :watch_id, :text, null: false
      add :ref, :text, null: false
      add :status, :text, null: false, default: "active"
      add :mode, :text, null: false, default: "notify"
      add :project, :text, null: false, default: ""
      add :session_type, :text, null: false, default: ""
      add :session_kind, :text, null: false, default: ""
      add :goal, :text, null: false, default: ""
      add :success_pattern, :text, null: false, default: ""
      add :blocker_pattern, :text, null: false, default: ""
      add :prompt, :text, null: false, default: ""
      add :last_summary, :text, null: false, default: ""
      add :result_summary, :text, null: false, default: ""
      add :last_observed_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:session_watches, [:watch_id])
    create index(:session_watches, [:ref])
    create index(:session_watches, [:status])
    create index(:session_watches, [:updated_at])
  end
end
