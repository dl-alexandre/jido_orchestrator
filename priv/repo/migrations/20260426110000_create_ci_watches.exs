defmodule JX.Repo.Migrations.CreateCiWatches do
  use Ecto.Migration

  def change do
    create table(:ci_watches) do
      add :watch_id, :text, null: false
      add :repo, :text, null: false
      add :pr_number, :integer, null: false
      add :ref, :text, null: false, default: ""
      add :project, :text, null: false, default: ""
      add :status, :text, null: false, default: "active"
      add :mode, :text, null: false, default: "notify"
      add :goal, :text, null: false, default: ""
      add :success_prompt, :text, null: false, default: ""
      add :failure_prompt, :text, null: false, default: ""
      add :last_overall, :text, null: false, default: ""
      add :last_summary, :text, null: false, default: ""
      add :last_digest, :text, null: false, default: "{}"
      add :last_checked_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ci_watches, [:watch_id])
    create index(:ci_watches, [:status])
    create index(:ci_watches, [:repo, :pr_number])
    create index(:ci_watches, [:ref])
    create index(:ci_watches, [:project])
    create index(:ci_watches, [:updated_at])
  end
end
