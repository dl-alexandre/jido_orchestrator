defmodule JX.OrchestratorHeartbeats.Heartbeat do
  @moduledoc """
  Durable heartbeat for an orchestration loop.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(running idle error stopped)

  @type t :: %__MODULE__{}

  schema "orchestrator_heartbeats" do
    field(:daemon_key, :string)
    field(:consumer, :string, default: "")
    field(:session_name, :string, default: "")
    field(:status, :string, default: "running")
    field(:mode, :string, default: "")
    field(:last_scan_at, :utc_datetime_usec)
    field(:last_decision_at, :utc_datetime_usec)
    field(:last_error, :string, default: "")
    field(:next_wake_at, :utc_datetime_usec)
    field(:scan_snapshot, :string, default: "{}")

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(heartbeat, attrs) do
    heartbeat
    |> cast(attrs, [
      :daemon_key,
      :consumer,
      :session_name,
      :status,
      :mode,
      :last_scan_at,
      :last_decision_at,
      :last_error,
      :next_wake_at,
      :scan_snapshot
    ])
    |> trim_fields([:daemon_key, :consumer, :session_name, :status, :mode, :last_error])
    |> validate_required([:daemon_key, :status, :scan_snapshot])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:daemon_key)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
