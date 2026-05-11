defmodule JX.Repo.Migrations.CreateWorkspaceTables do
  use Ecto.Migration

  def change do
    create table(:hosts) do
      add :name, :text, null: false
      add :ssh_target, :text, null: false
      add :workspace_path, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:hosts, [:name])

    create table(:projects) do
      add :name, :text, null: false
      add :slug, :text, null: false
      add :repo_path, :text, null: false
      add :host_id, references(:hosts, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:name])
    create unique_index(:projects, [:slug])
    create index(:projects, [:host_id])

    create table(:tasks) do
      add :task_id, :text, null: false
      add :prompt_hash, :text, null: false
      add :prompt, :text, null: false
      add :agent_name, :text, null: false
      add :branch, :text, null: false
      add :worktree_path, :text, null: false
      add :task_dir, :text, null: false
      add :log_path, :text, null: false
      add :session_name, :text, null: false
      add :status, :text, null: false
      add :last_error, :text, null: false, default: ""
      add :project_id, references(:projects, on_delete: :restrict), null: false
      add :host_id, references(:hosts, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tasks, [:task_id])
    create unique_index(:tasks, [:project_id, :prompt_hash])
    create index(:tasks, [:status])
    create index(:tasks, [:host_id])
  end
end

