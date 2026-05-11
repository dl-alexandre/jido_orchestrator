defmodule JX.WakeTriggers.WakeTrigger do
  @moduledoc """
  Durable scheduled external wake trigger.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias JX.MonitorEvents

  @statuses ~w(active disabled completed cancelled)
  @schedules ~w(once every)

  @type t :: %__MODULE__{}

  schema "wake_triggers" do
    field(:trigger_id, :string)
    field(:name, :string, default: "")
    field(:status, :string, default: "active")
    field(:message, :string)
    field(:project, :string, default: "")
    field(:ref, :string, default: "")
    field(:severity, :string, default: "warning")
    field(:schedule, :string, default: "once")
    field(:every_seconds, :integer)
    field(:next_run_at, :utc_datetime_usec)
    field(:last_run_at, :utc_datetime_usec)
    field(:run_count, :integer, default: 0)
    field(:last_result, :string, default: "")

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def schedules, do: @schedules

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [
      :trigger_id,
      :name,
      :status,
      :message,
      :project,
      :ref,
      :severity,
      :schedule,
      :every_seconds,
      :next_run_at,
      :last_run_at,
      :run_count,
      :last_result
    ])
    |> trim_fields([
      :trigger_id,
      :name,
      :status,
      :message,
      :project,
      :ref,
      :severity,
      :schedule,
      :last_result
    ])
    |> validate_required([:trigger_id, :status, :message, :severity, :schedule])
    |> validate_number(:run_count, greater_than_or_equal_to: 0)
    |> validate_number(:every_seconds, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:schedule, @schedules)
    |> validate_inclusion(:severity, MonitorEvents.Event.severities())
    |> validate_schedule()
    |> validate_active_next_run_at()
    |> unique_constraint(:trigger_id)
  end

  defp validate_schedule(changeset) do
    case get_field(changeset, :schedule) do
      "every" -> validate_required(changeset, [:every_seconds])
      _schedule -> changeset
    end
  end

  defp validate_active_next_run_at(changeset) do
    case get_field(changeset, :status) do
      "active" -> validate_required(changeset, [:next_run_at])
      _status -> changeset
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
