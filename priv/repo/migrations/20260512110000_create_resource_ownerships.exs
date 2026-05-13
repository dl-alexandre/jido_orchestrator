defmodule JX.Repo.Migrations.CreateResourceOwnerships do
  use Ecto.Migration

  def change do
    create table(:resource_ownerships) do
      add(:resource_id, :text, null: false)
      add(:owner_project, :text, null: false)
      add(:assignment_id, :text, null: false, default: "")
      add(:execution_id, :text, null: false, default: "")
      add(:resource_type, :text, null: false)
      add(:resource_name, :text, null: false)
      add(:resource_path, :text, null: false, default: "")
      add(:tmux_server, :text, null: false, default: "")
      add(:cleanup_policy, :text, null: false)
      add(:state, :text, null: false, default: "created")
      add(:reason, :text, null: false, default: "")
      add(:metadata, :text, null: false, default: "{}")
      add(:created_at, :utc_datetime_usec, null: false)
      add(:ended_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:resource_ownerships, [:resource_id]))
    create(unique_index(:resource_ownerships, [:resource_type, :resource_name, :resource_path]))
    create(index(:resource_ownerships, [:owner_project]))
    create(index(:resource_ownerships, [:assignment_id]))
    create(index(:resource_ownerships, [:execution_id]))
    create(index(:resource_ownerships, [:resource_type]))
    create(index(:resource_ownerships, [:state]))
    create(index(:resource_ownerships, [:cleanup_policy]))
    create(index(:resource_ownerships, [:created_at]))
  end
end
