defmodule JX.Repo.Migrations.CreateOrchestrationLayers do
  use Ecto.Migration

  def change do
    alter table(:session_profiles) do
      add :owner, :text, null: false, default: ""
      add :risk_level, :text, null: false, default: "normal"
      add :lifecycle_status, :text, null: false, default: "active"
      add :current_hypothesis, :text, null: false, default: ""
      add :last_evidence, :text, null: false, default: ""
      add :stale_after_seconds, :integer
    end

    create index(:session_profiles, [:owner])
    create index(:session_profiles, [:risk_level])
    create index(:session_profiles, [:lifecycle_status])

    create table(:orchestration_actions) do
      add :action_id, :text, null: false
      add :queue_key, :text, null: false
      add :requested, :text, null: false, default: ""
      add :source, :text, null: false, default: ""
      add :recommendation_id, :text, null: false, default: ""
      add :action, :text, null: false, default: ""
      add :safety, :text, null: false, default: ""
      add :ref, :text, null: false, default: ""
      add :target, :text, null: false, default: ""
      add :status, :text, null: false, default: "planned"
      add :reason, :text, null: false, default: ""
      add :error, :text, null: false, default: ""
      add :result_summary, :text, null: false, default: ""
      add :payload, :text, null: false, default: "{}"
      add :scheduled_at, :utc_datetime_usec
      add :executed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:orchestration_actions, [:action_id])
    create unique_index(:orchestration_actions, [:queue_key])
    create index(:orchestration_actions, [:status])
    create index(:orchestration_actions, [:source])
    create index(:orchestration_actions, [:ref])
    create index(:orchestration_actions, [:action])
    create index(:orchestration_actions, [:updated_at])

    create table(:orchestrator_heartbeats) do
      add :daemon_key, :text, null: false
      add :consumer, :text, null: false, default: ""
      add :session_name, :text, null: false, default: ""
      add :status, :text, null: false, default: "running"
      add :mode, :text, null: false, default: ""
      add :last_scan_at, :utc_datetime_usec
      add :last_decision_at, :utc_datetime_usec
      add :last_error, :text, null: false, default: ""
      add :next_wake_at, :utc_datetime_usec
      add :scan_snapshot, :text, null: false, default: "{}"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:orchestrator_heartbeats, [:daemon_key])
    create index(:orchestrator_heartbeats, [:consumer])
    create index(:orchestrator_heartbeats, [:status])
    create index(:orchestrator_heartbeats, [:updated_at])

    create table(:notifications) do
      add :notification_id, :text, null: false
      add :source_event_id, :text, null: false, default: ""
      add :kind, :text, null: false, default: ""
      add :severity, :text, null: false, default: "info"
      add :status, :text, null: false, default: "unread"
      add :ref, :text, null: false, default: ""
      add :project, :text, null: false, default: ""
      add :summary, :text, null: false, default: ""
      add :payload, :text, null: false, default: "{}"
      add :acknowledged_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:notifications, [:notification_id])
    create unique_index(:notifications, [:source_event_id])
    create index(:notifications, [:status])
    create index(:notifications, [:severity])
    create index(:notifications, [:kind])
    create index(:notifications, [:ref])
    create index(:notifications, [:project])
    create index(:notifications, [:updated_at])
  end
end
