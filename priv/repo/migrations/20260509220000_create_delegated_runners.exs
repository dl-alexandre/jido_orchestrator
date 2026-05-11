defmodule JX.Repo.Migrations.CreateDelegatedRunners do
  use Ecto.Migration

  def change do
    alter table(:delegated_assignments) do
      add(:runner_id, :text, null: false, default: "")
      add(:session_id, :text, null: false, default: "")
    end

    create(index(:delegated_assignments, [:runner_id]))
    create(index(:delegated_assignments, [:session_id]))

    create table(:delegated_runners) do
      add(:runner_id, :text, null: false)
      add(:agent_id, :text, null: false)
      add(:host_name, :text, null: false, default: "")
      add(:status, :text, null: false, default: "idle")
      add(:capabilities, :text, null: false, default: "[]")
      add(:workspace_affinity, :text, null: false, default: "[]")
      add(:heartbeat_ttl_seconds, :integer, null: false, default: 120)
      add(:last_heartbeat_at, :utc_datetime_usec)
      add(:tmux_server, :text, null: false, default: "")
      add(:tmux_session_prefix, :text, null: false, default: "")
      add(:metadata, :text, null: false, default: "{}")

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:delegated_runners, [:runner_id]))
    create(index(:delegated_runners, [:agent_id]))
    create(index(:delegated_runners, [:host_name]))
    create(index(:delegated_runners, [:status]))
    create(index(:delegated_runners, [:last_heartbeat_at]))

    create table(:delegated_runner_sessions) do
      add(:session_id, :text, null: false)
      add(:runner_id, :text, null: false)
      add(:agent_id, :text, null: false, default: "")
      add(:assignment_id, :text, null: false, default: "")
      add(:workspace_id, :text, null: false, default: "")
      add(:action_id, :text, null: false, default: "")
      add(:approval_id, :text, null: false, default: "")
      add(:status, :text, null: false, default: "created")
      add(:active_assignment_key, :text)
      add(:correlation_id, :text, null: false, default: "")
      add(:tmux_server, :text, null: false, default: "")
      add(:tmux_session_name, :text, null: false, default: "")
      add(:log_path, :text, null: false, default: "")
      add(:last_summary, :text, null: false, default: "")
      add(:metadata, :text, null: false, default: "{}")
      add(:started_at, :utc_datetime_usec)
      add(:heartbeat_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:delegated_runner_sessions, [:session_id]))
    create(unique_index(:delegated_runner_sessions, [:active_assignment_key]))
    create(index(:delegated_runner_sessions, [:runner_id]))
    create(index(:delegated_runner_sessions, [:agent_id]))
    create(index(:delegated_runner_sessions, [:assignment_id]))
    create(index(:delegated_runner_sessions, [:workspace_id]))
    create(index(:delegated_runner_sessions, [:action_id]))
    create(index(:delegated_runner_sessions, [:approval_id]))
    create(index(:delegated_runner_sessions, [:status]))
    create(index(:delegated_runner_sessions, [:heartbeat_at]))
    create(index(:delegated_runner_sessions, [:expires_at]))

    create table(:delegated_runner_reports) do
      add(:report_id, :text, null: false)
      add(:session_id, :text, null: false, default: "")
      add(:runner_id, :text, null: false)
      add(:agent_id, :text, null: false, default: "")
      add(:assignment_id, :text, null: false, default: "")
      add(:workspace_id, :text, null: false, default: "")
      add(:action_id, :text, null: false, default: "")
      add(:kind, :text, null: false)
      add(:status, :text, null: false, default: "")
      add(:correlation_id, :text, null: false, default: "")
      add(:fingerprint, :text, null: false)
      add(:summary, :text, null: false, default: "")
      add(:payload, :text, null: false, default: "{}")

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:delegated_runner_reports, [:report_id]))
    create(unique_index(:delegated_runner_reports, [:fingerprint]))
    create(index(:delegated_runner_reports, [:session_id]))
    create(index(:delegated_runner_reports, [:runner_id]))
    create(index(:delegated_runner_reports, [:assignment_id]))
    create(index(:delegated_runner_reports, [:workspace_id]))
    create(index(:delegated_runner_reports, [:action_id]))
    create(index(:delegated_runner_reports, [:kind]))
    create(index(:delegated_runner_reports, [:correlation_id]))
  end
end
