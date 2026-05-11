defmodule JX.Repo.Migrations.CreateSafeActionEvents do
  use Ecto.Migration

  def change do
    create table(:safe_action_events) do
      add(:event_id, :text, null: false)
      add(:action_id, :text, null: false)
      add(:approval_id, :text, null: false, default: "")
      add(:workspace_id, :text, null: false, default: "")
      add(:command_id, :text, null: false, default: "")
      add(:kind, :text, null: false)
      add(:reason, :text, null: false, default: "")
      add(:payload, :text, null: false, default: "{}")

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:safe_action_events, [:event_id]))
    create(index(:safe_action_events, [:action_id]))
    create(index(:safe_action_events, [:approval_id]))
    create(index(:safe_action_events, [:kind]))
    create(index(:safe_action_events, [:inserted_at]))
  end
end
