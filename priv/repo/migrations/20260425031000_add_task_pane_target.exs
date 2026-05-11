defmodule JX.Repo.Migrations.AddTaskPaneTarget do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :window, :integer, null: false, default: 0
      add :pane, :integer, null: false, default: 0
    end

    create index(:tasks, [:project_id, :tmux_server, :session_name, :window, :pane])
  end
end
