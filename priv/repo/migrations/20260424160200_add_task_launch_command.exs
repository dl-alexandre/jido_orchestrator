defmodule JX.Repo.Migrations.AddTaskLaunchCommand do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :launch_command, :text, null: false, default: ""
    end
  end
end
