defmodule JX.Repo.Migrations.AddTaskTmuxServer do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add(:tmux_server, :string, null: false, default: "jx")
    end
  end
end
