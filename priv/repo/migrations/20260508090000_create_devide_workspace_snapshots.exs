defmodule JX.Repo.Migrations.CreateDevideWorkspaceSnapshots do
  use Ecto.Migration

  def change do
    create table(:devide_workspace_snapshots) do
      add(:workspace_id, :text, null: false)
      add(:name, :text, null: false, default: "")
      add(:lifecycle_status, :text, null: false, default: "")
      add(:status, :text, null: false, default: "unknown")
      add(:mode, :text, null: false, default: "")
      add(:db_isolation, :text, null: false, default: "unknown")
      add(:attention_flags, :text, null: false, default: "[]")
      add(:snapshot, :text, null: false, default: "{}")
      add(:fingerprint, :text, null: false)
      add(:source_url, :text, null: false, default: "")
      add(:last_observed_at, :utc_datetime_usec)
      add(:last_changed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:devide_workspace_snapshots, [:workspace_id]))
    create(index(:devide_workspace_snapshots, [:status]))
    create(index(:devide_workspace_snapshots, [:source_url]))
    create(index(:devide_workspace_snapshots, [:last_observed_at]))
    create(index(:devide_workspace_snapshots, [:last_changed_at]))
  end
end
