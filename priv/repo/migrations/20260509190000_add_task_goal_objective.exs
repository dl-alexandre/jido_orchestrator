defmodule JX.Repo.Migrations.AddTaskGoalObjective do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add(:goal_objective, :text, null: false, default: "")
    end
  end
end
