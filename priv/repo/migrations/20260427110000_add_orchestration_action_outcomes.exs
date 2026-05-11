defmodule JX.Repo.Migrations.AddOrchestrationActionOutcomes do
  use Ecto.Migration

  def change do
    alter table(:orchestration_actions) do
      add(:outcome, :text, null: false, default: "")
      add(:outcome_reason, :text, null: false, default: "")
      add(:completed_at, :utc_datetime_usec)
    end

    create(index(:orchestration_actions, [:outcome]))
    create(index(:orchestration_actions, [:completed_at]))
  end
end
