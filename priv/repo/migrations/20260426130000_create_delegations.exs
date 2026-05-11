defmodule JX.Repo.Migrations.CreateDelegations do
  use Ecto.Migration

  def change do
    create table(:delegations) do
      add(:delegation_id, :text, null: false)
      add(:status, :text, null: false, default: "queued")
      add(:priority, :integer, null: false, default: 0)
      add(:project, :text, null: false, default: "")
      add(:ref, :text, null: false, default: "")
      add(:source, :text, null: false, default: "foreground")
      add(:owner, :text, null: false, default: "")
      add(:agent_kind, :text, null: false, default: "worker")
      add(:title, :text, null: false, default: "")
      add(:brief, :text, null: false, default: "")
      add(:context, :text, null: false, default: "[]")
      add(:constraints, :text, null: false, default: "[]")
      add(:acceptance, :text, null: false, default: "[]")
      add(:verification, :text, null: false, default: "[]")
      add(:worker_summary, :text, null: false, default: "")
      add(:artifacts, :text, null: false, default: "[]")
      add(:payload, :text, null: false, default: "{}")
      add(:claimed_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:delegations, [:delegation_id]))
    create(index(:delegations, [:status]))
    create(index(:delegations, [:project]))
    create(index(:delegations, [:ref]))
    create(index(:delegations, [:owner]))
    create(index(:delegations, [:priority]))
    create(index(:delegations, [:updated_at]))
  end
end
