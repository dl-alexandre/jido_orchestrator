defmodule JX.Repo.Migrations.CreateDelegatedExecution do
  use Ecto.Migration

  def change do
    create table(:delegated_agents) do
      add(:agent_id, :text, null: false)
      add(:name, :text, null: false, default: "")
      add(:status, :text, null: false, default: "idle")
      add(:capabilities, :text, null: false, default: "[]")
      add(:workspace_affinity, :text, null: false, default: "[]")
      add(:heartbeat_ttl_seconds, :integer, null: false, default: 120)
      add(:last_heartbeat_at, :utc_datetime_usec)
      add(:metadata, :text, null: false, default: "{}")

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:delegated_agents, [:agent_id]))
    create(index(:delegated_agents, [:status]))
    create(index(:delegated_agents, [:last_heartbeat_at]))

    create table(:delegated_assignments) do
      add(:assignment_id, :text, null: false)
      add(:action_id, :text, null: false)
      add(:approval_id, :text, null: false, default: "")
      add(:workspace_id, :text, null: false, default: "")
      add(:safe_action_kind, :text, null: false, default: "")
      add(:status, :text, null: false, default: "created")
      add(:active_claim_key, :text)
      add(:claimant_agent_id, :text, null: false, default: "")
      add(:lease_id, :text, null: false, default: "")
      add(:correlation_id, :text, null: false, default: "")
      add(:required_capabilities, :text, null: false, default: "[]")
      add(:summary, :text, null: false, default: "")
      add(:metadata, :text, null: false, default: "{}")
      add(:claimed_at, :utc_datetime_usec)
      add(:started_at, :utc_datetime_usec)
      add(:last_report_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:delegated_assignments, [:assignment_id]))
    create(unique_index(:delegated_assignments, [:active_claim_key]))
    create(index(:delegated_assignments, [:action_id]))
    create(index(:delegated_assignments, [:approval_id]))
    create(index(:delegated_assignments, [:workspace_id]))
    create(index(:delegated_assignments, [:claimant_agent_id]))
    create(index(:delegated_assignments, [:status]))
    create(index(:delegated_assignments, [:expires_at]))

    create table(:delegated_assignment_reports) do
      add(:report_id, :text, null: false)
      add(:assignment_id, :text, null: false)
      add(:agent_id, :text, null: false)
      add(:action_id, :text, null: false, default: "")
      add(:workspace_id, :text, null: false, default: "")
      add(:kind, :text, null: false)
      add(:status, :text, null: false, default: "")
      add(:correlation_id, :text, null: false, default: "")
      add(:fingerprint, :text, null: false)
      add(:summary, :text, null: false, default: "")
      add(:payload, :text, null: false, default: "{}")

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:delegated_assignment_reports, [:report_id]))
    create(unique_index(:delegated_assignment_reports, [:fingerprint]))
    create(index(:delegated_assignment_reports, [:assignment_id]))
    create(index(:delegated_assignment_reports, [:agent_id]))
    create(index(:delegated_assignment_reports, [:action_id]))
    create(index(:delegated_assignment_reports, [:workspace_id]))
    create(index(:delegated_assignment_reports, [:kind]))
    create(index(:delegated_assignment_reports, [:correlation_id]))
  end
end
