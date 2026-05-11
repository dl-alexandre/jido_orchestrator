defmodule JX.Repo.Migrations.CreateProfiles do
  use Ecto.Migration

  def change do
    create table(:session_profiles) do
      add :ref, :text, null: false
      add :summary, :text, null: false, default: ""
      add :objective, :text, null: false, default: ""
      add :expected_completion, :text, null: false, default: ""
      add :next_prompt, :text, null: false, default: ""
      add :prompt_status, :text, null: false, default: "none"
      add :strategy, :text, null: false, default: ""
      add :notes, :text, null: false, default: ""
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:session_profiles, [:ref])
    create index(:session_profiles, [:prompt_status])
    create index(:session_profiles, [:last_seen_at])

    create table(:operator_profiles) do
      add :profile_key, :text, null: false
      add :name, :text, null: false, default: ""
      add :preferences, :text, null: false, default: ""
      add :working_style, :text, null: false, default: ""
      add :escalation_policy, :text, null: false, default: ""
      add :notes, :text, null: false, default: ""

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:operator_profiles, [:profile_key])
  end
end
