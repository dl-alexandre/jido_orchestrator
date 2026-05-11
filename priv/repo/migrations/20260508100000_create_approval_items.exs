defmodule JX.Repo.Migrations.CreateApprovalItems do
  use Ecto.Migration

  def change do
    create table(:approval_items) do
      add(:approval_id, :text, null: false)
      add(:source, :text, null: false, default: "devide")
      add(:workspace_id, :text, null: false, default: "")
      add(:kind, :text, null: false)
      add(:severity, :text, null: false, default: "warning")
      add(:target_ref, :text, null: false, default: "")
      add(:summary, :text, null: false, default: "")
      add(:status, :text, null: false, default: "open")
      add(:metadata, :text, null: false, default: "{}")
      add(:dedupe_key, :text, null: false)
      add(:acknowledged_at, :utc_datetime_usec)
      add(:dismissed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:approval_items, [:approval_id]))
    create(index(:approval_items, [:source]))
    create(index(:approval_items, [:workspace_id]))
    create(index(:approval_items, [:kind]))
    create(index(:approval_items, [:status]))
    create(index(:approval_items, [:dedupe_key]))
    create(index(:approval_items, [:updated_at]))
  end
end
