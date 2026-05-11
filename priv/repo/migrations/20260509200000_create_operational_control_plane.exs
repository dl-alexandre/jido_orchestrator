defmodule JX.Repo.Migrations.CreateOperationalControlPlane do
  use Ecto.Migration

  def change do
    create table(:operational_events) do
      add(:event_id, :text, null: false)
      add(:correlation_id, :text, null: false, default: "")
      add(:source, :text, null: false, default: "")
      add(:kind, :text, null: false)
      add(:entity_type, :text, null: false, default: "")
      add(:entity_id, :text, null: false, default: "")
      add(:workspace_id, :text, null: false, default: "")
      add(:approval_id, :text, null: false, default: "")
      add(:action_id, :text, null: false, default: "")
      add(:lease_id, :text, null: false, default: "")
      add(:owner, :text, null: false, default: "")
      add(:severity, :text, null: false, default: "info")
      add(:summary, :text, null: false, default: "")
      add(:payload, :text, null: false, default: "{}")
      add(:caused_by_event_id, :text, null: false, default: "")

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:operational_events, [:event_id]))
    create(index(:operational_events, [:correlation_id]))
    create(index(:operational_events, [:kind]))
    create(index(:operational_events, [:entity_type, :entity_id]))
    create(index(:operational_events, [:workspace_id]))
    create(index(:operational_events, [:approval_id]))
    create(index(:operational_events, [:action_id]))
    create(index(:operational_events, [:lease_id]))
    create(index(:operational_events, [:owner]))
    create(index(:operational_events, [:inserted_at]))

    create table(:operational_leases) do
      add(:lease_id, :text, null: false)
      add(:resource_type, :text, null: false)
      add(:resource_id, :text, null: false)
      add(:active_key, :text)
      add(:owner, :text, null: false)
      add(:status, :text, null: false, default: "active")
      add(:correlation_id, :text, null: false, default: "")
      add(:reason, :text, null: false, default: "")
      add(:metadata, :text, null: false, default: "{}")
      add(:acquired_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec)
      add(:released_at, :utc_datetime_usec)
      add(:reassigned_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:operational_leases, [:lease_id]))
    create(unique_index(:operational_leases, [:active_key]))
    create(index(:operational_leases, [:resource_type, :resource_id]))
    create(index(:operational_leases, [:owner]))
    create(index(:operational_leases, [:status]))
    create(index(:operational_leases, [:expires_at]))
  end
end
