defmodule JX.Repo.Migrations.CreateRuntimeEnvironments do
  use Ecto.Migration

  def change do
    create table(:runtime_environments) do
      add(:runtime_id, :text, null: false)
      add(:workspace_id, :text, null: false, default: "")
      add(:action_id, :text, null: false, default: "")
      add(:assignment_id, :text, null: false, default: "")
      add(:runner_id, :text, null: false, default: "")
      add(:project_name, :text, null: false, default: "")
      add(:host_name, :text, null: false, default: "")
      add(:repo_path, :text, null: false, default: "")
      add(:worktree_path, :text, null: false, default: "")
      add(:branch, :text, null: false, default: "")
      add(:status, :text, null: false, default: "planned")
      add(:capabilities, :text, null: false, default: "[]")
      add(:tools, :text, null: false, default: "[]")
      add(:os, :text, null: false, default: "")
      add(:branch_isolation, :text, null: false, default: "worktree")
      add(:concurrency_limit, :integer, null: false, default: 1)
      add(:reusable, :boolean, null: false, default: true)
      add(:correlation_id, :text, null: false, default: "")
      add(:metadata, :text, null: false, default: "{}")
      add(:last_error, :text, null: false, default: "")
      add(:provisioned_at, :utc_datetime_usec)
      add(:assigned_at, :utc_datetime_usec)
      add(:released_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:runtime_environments, [:runtime_id]))
    create(index(:runtime_environments, [:workspace_id]))
    create(index(:runtime_environments, [:action_id]))
    create(index(:runtime_environments, [:assignment_id]))
    create(index(:runtime_environments, [:runner_id]))
    create(index(:runtime_environments, [:host_name]))
    create(index(:runtime_environments, [:status]))
    create(index(:runtime_environments, [:expires_at]))
  end
end
