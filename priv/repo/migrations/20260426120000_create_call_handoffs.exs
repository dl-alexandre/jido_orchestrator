defmodule JX.Repo.Migrations.CreateCallHandoffs do
  use Ecto.Migration

  def change do
    create table(:call_handoffs) do
      add(:handoff_id, :text, null: false)
      add(:surface, :text, null: false, default: "call")
      add(:status, :text, null: false, default: "open")
      add(:project, :text, null: false, default: "")
      add(:ref, :text, null: false, default: "")
      add(:title, :text, null: false, default: "")
      add(:summary, :text, null: false, default: "")
      add(:operator_input, :text, null: false, default: "")
      add(:decisions, :text, null: false, default: "[]")
      add(:follow_ups, :text, null: false, default: "[]")
      add(:brief_snapshot, :text, null: false, default: "{}")
      add(:payload, :text, null: false, default: "{}")
      add(:closed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:call_handoffs, [:handoff_id]))
    create(index(:call_handoffs, [:surface]))
    create(index(:call_handoffs, [:status]))
    create(index(:call_handoffs, [:project]))
    create(index(:call_handoffs, [:ref]))
    create(index(:call_handoffs, [:updated_at]))
  end
end
