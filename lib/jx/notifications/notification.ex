defmodule JX.Notifications.Notification do
  @moduledoc """
  Compact unread item derived from monitor events.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(unread acknowledged dismissed)
  @severities ~w(info notice warning critical)

  @type t :: %__MODULE__{}

  schema "notifications" do
    field(:notification_id, :string)
    field(:source_event_id, :string, default: "")
    field(:kind, :string, default: "")
    field(:severity, :string, default: "info")
    field(:status, :string, default: "unread")
    field(:ref, :string, default: "")
    field(:project, :string, default: "")
    field(:summary, :string, default: "")
    field(:payload, :string, default: "{}")
    field(:acknowledged_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def severities, do: @severities

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [
      :notification_id,
      :source_event_id,
      :kind,
      :severity,
      :status,
      :ref,
      :project,
      :summary,
      :payload,
      :acknowledged_at
    ])
    |> trim_fields([
      :notification_id,
      :source_event_id,
      :kind,
      :severity,
      :status,
      :ref,
      :project,
      :summary
    ])
    |> validate_required([:notification_id, :kind, :severity, :status, :payload])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:severity, @severities)
    |> unique_constraint(:notification_id)
    |> unique_constraint(:source_event_id)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
