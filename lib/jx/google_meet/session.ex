defmodule JX.GoogleMeet.Session do
  @moduledoc """
  Durable Google Meet participant session.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(planned joining live recovered ended failed)
  @twilio_modes ~w(none start connect)
  @twilio_tracks ~w(inbound_track outbound_track both_tracks)

  @type t :: %__MODULE__{}

  schema "google_meet_sessions" do
    field(:session_id, :string)
    field(:status, :string, default: "planned")
    field(:meeting_uri, :string)
    field(:meeting_code, :string)
    field(:title, :string, default: "")
    field(:project, :string, default: "")
    field(:ref, :string, default: "")
    field(:auth_profile, :string, default: "personal")
    field(:google_space, :string, default: "")
    field(:conference_record, :string, default: "")
    field(:chrome_node, :string, default: "")
    field(:paired_chrome_node, :string, default: "")
    field(:chrome_target, :string, default: "{}")
    field(:paired_chrome_target, :string, default: "{}")
    field(:twilio_mode, :string, default: "none")
    field(:twilio_stream_url, :string, default: "")
    field(:twilio_track, :string, default: "inbound_track")
    field(:twilio_call_sid, :string, default: "")
    field(:websocket_url, :string, default: "")
    field(:artifact_dir, :string, default: "")
    field(:attendance, :string, default: "[]")
    field(:artifacts, :string, default: "{}")
    field(:recovery, :string, default: "{}")
    field(:realtime, :string, default: "{}")
    field(:handoff_id, :string, default: "")
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def twilio_modes, do: @twilio_modes
  def twilio_tracks, do: @twilio_tracks

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :session_id,
      :status,
      :meeting_uri,
      :meeting_code,
      :title,
      :project,
      :ref,
      :auth_profile,
      :google_space,
      :conference_record,
      :chrome_node,
      :paired_chrome_node,
      :chrome_target,
      :paired_chrome_target,
      :twilio_mode,
      :twilio_stream_url,
      :twilio_track,
      :twilio_call_sid,
      :websocket_url,
      :artifact_dir,
      :attendance,
      :artifacts,
      :recovery,
      :realtime,
      :handoff_id,
      :started_at,
      :ended_at
    ])
    |> trim_fields([
      :session_id,
      :status,
      :meeting_uri,
      :meeting_code,
      :title,
      :project,
      :ref,
      :auth_profile,
      :google_space,
      :conference_record,
      :chrome_node,
      :paired_chrome_node,
      :chrome_target,
      :paired_chrome_target,
      :twilio_mode,
      :twilio_stream_url,
      :twilio_track,
      :twilio_call_sid,
      :websocket_url,
      :artifact_dir,
      :attendance,
      :artifacts,
      :recovery,
      :realtime,
      :handoff_id
    ])
    |> validate_required([
      :session_id,
      :status,
      :meeting_uri,
      :meeting_code,
      :auth_profile,
      :twilio_mode,
      :twilio_track,
      :attendance,
      :artifacts,
      :recovery,
      :realtime
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:twilio_mode, @twilio_modes)
    |> validate_inclusion(:twilio_track, @twilio_tracks)
    |> validate_format(:meeting_code, ~r/^[a-z]+-[a-z]+-[a-z]+$/)
    |> validate_twilio_track()
    |> unique_constraint(:session_id)
  end

  defp validate_twilio_track(changeset) do
    case {get_field(changeset, :twilio_mode), get_field(changeset, :twilio_track)} do
      {"connect", track} when track != "inbound_track" ->
        add_error(changeset, :twilio_track, "must be inbound_track for Twilio connect mode")

      _other ->
        changeset
    end
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(to_string(value))
end
