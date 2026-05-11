defmodule JX.Repo.Migrations.CreateGoogleMeetParticipantTables do
  use Ecto.Migration

  def change do
    create table(:google_meet_auth_profiles) do
      add(:profile_id, :text, null: false)
      add(:name, :text, null: false)
      add(:email, :text, null: false, default: "")
      add(:status, :text, null: false, default: "configured")
      add(:client_id, :text, null: false, default: "")
      add(:client_secret_env, :text, null: false, default: "")
      add(:redirect_uri, :text, null: false, default: "")
      add(:scopes, :text, null: false, default: "[]")
      add(:token, :text, null: false, default: "{}")
      add(:pending_auth, :text, null: false, default: "{}")
      add(:last_error, :text, null: false, default: "")
      add(:authenticated_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:google_meet_auth_profiles, [:profile_id]))
    create(unique_index(:google_meet_auth_profiles, [:name]))
    create(index(:google_meet_auth_profiles, [:email]))
    create(index(:google_meet_auth_profiles, [:status]))

    create table(:google_meet_sessions) do
      add(:session_id, :text, null: false)
      add(:status, :text, null: false, default: "planned")
      add(:meeting_uri, :text, null: false)
      add(:meeting_code, :text, null: false)
      add(:title, :text, null: false, default: "")
      add(:project, :text, null: false, default: "")
      add(:ref, :text, null: false, default: "")
      add(:auth_profile, :text, null: false, default: "personal")
      add(:google_space, :text, null: false, default: "")
      add(:conference_record, :text, null: false, default: "")
      add(:chrome_node, :text, null: false, default: "")
      add(:paired_chrome_node, :text, null: false, default: "")
      add(:chrome_target, :text, null: false, default: "{}")
      add(:paired_chrome_target, :text, null: false, default: "{}")
      add(:twilio_mode, :text, null: false, default: "none")
      add(:twilio_stream_url, :text, null: false, default: "")
      add(:twilio_track, :text, null: false, default: "inbound_track")
      add(:twilio_call_sid, :text, null: false, default: "")
      add(:websocket_url, :text, null: false, default: "")
      add(:artifact_dir, :text, null: false, default: "")
      add(:attendance, :text, null: false, default: "[]")
      add(:artifacts, :text, null: false, default: "{}")
      add(:recovery, :text, null: false, default: "{}")
      add(:realtime, :text, null: false, default: "{}")
      add(:handoff_id, :text, null: false, default: "")
      add(:started_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:google_meet_sessions, [:session_id]))
    create(index(:google_meet_sessions, [:meeting_code]))
    create(index(:google_meet_sessions, [:status]))
    create(index(:google_meet_sessions, [:project]))
    create(index(:google_meet_sessions, [:ref]))
    create(index(:google_meet_sessions, [:auth_profile]))
    create(index(:google_meet_sessions, [:updated_at]))
  end
end
