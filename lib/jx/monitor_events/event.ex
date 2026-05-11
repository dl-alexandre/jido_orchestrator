defmodule JX.MonitorEvents.Event do
  @moduledoc """
  Deduplicated orchestration event emitted by monitor scans.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @severities ~w(info notice warning critical)

  @type t :: %__MODULE__{}

  schema "monitor_events" do
    field(:event_id, :string)
    field(:kind, :string)
    field(:severity, :string)
    field(:ref, :string, default: "")
    field(:project, :string, default: "")
    field(:session_type, :string, default: "")
    field(:session_kind, :string, default: "")
    field(:control_mode, :string, default: "")
    field(:work_state, :string, default: "")
    field(:action, :string, default: "")
    field(:summary, :string, default: "")
    field(:fingerprint, :string)
    field(:payload, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def severities, do: @severities

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_id,
      :kind,
      :severity,
      :ref,
      :project,
      :session_type,
      :session_kind,
      :control_mode,
      :work_state,
      :action,
      :summary,
      :fingerprint,
      :payload
    ])
    |> update_change(:event_id, &trim/1)
    |> update_change(:kind, &trim/1)
    |> update_change(:severity, &trim/1)
    |> update_change(:ref, &trim/1)
    |> update_change(:project, &trim/1)
    |> update_change(:session_type, &trim/1)
    |> update_change(:session_kind, &trim/1)
    |> update_change(:control_mode, &trim/1)
    |> update_change(:work_state, &trim/1)
    |> update_change(:action, &trim/1)
    |> update_change(:summary, &trim/1)
    |> update_change(:fingerprint, &trim/1)
    |> validate_required([:event_id, :kind, :severity, :fingerprint, :payload])
    |> validate_inclusion(:severity, @severities)
    |> unique_constraint(:event_id)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
