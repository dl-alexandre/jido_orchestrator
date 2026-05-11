defmodule JX.Repo.Migrations.AddSafeActionEventCorrelation do
  use Ecto.Migration

  def change do
    alter table(:safe_action_events) do
      add(:correlation_id, :text, null: false, default: "")
      add(:outcome, :text, null: false, default: "")
    end

    create(index(:safe_action_events, [:correlation_id]))
    create(index(:safe_action_events, [:outcome]))
  end
end
