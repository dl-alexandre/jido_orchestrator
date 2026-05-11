defmodule JX.MonitorEvents.Cursor do
  @moduledoc """
  Durable consumer cursor for the monitor event journal.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "monitor_event_cursors" do
    field(:consumer, :string)
    field(:last_event_id, :integer, default: 0)
    field(:last_seen_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, [:consumer, :last_event_id, :last_seen_at])
    |> update_change(:consumer, &trim/1)
    |> validate_required([:consumer, :last_event_id])
    |> validate_number(:last_event_id, greater_than_or_equal_to: 0)
    |> unique_constraint(:consumer)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
