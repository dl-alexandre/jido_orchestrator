defmodule JX.SessionWatches.SessionWatch do
  @moduledoc """
  Durable background watch contract for a session ref.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active completed blocked cancelled)
  @modes ~w(notify hold prompt)

  @type t :: %__MODULE__{}

  schema "session_watches" do
    field(:watch_id, :string)
    field(:ref, :string)
    field(:status, :string, default: "active")
    field(:mode, :string, default: "notify")
    field(:project, :string, default: "")
    field(:session_type, :string, default: "")
    field(:session_kind, :string, default: "")
    field(:goal, :string, default: "")
    field(:success_pattern, :string, default: "")
    field(:blocker_pattern, :string, default: "")
    field(:prompt, :string, default: "")
    field(:last_summary, :string, default: "")
    field(:result_summary, :string, default: "")
    field(:last_observed_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def modes, do: @modes

  def changeset(watch, attrs) do
    watch
    |> cast(attrs, [
      :watch_id,
      :ref,
      :status,
      :mode,
      :project,
      :session_type,
      :session_kind,
      :goal,
      :success_pattern,
      :blocker_pattern,
      :prompt,
      :last_summary,
      :result_summary,
      :last_observed_at,
      :completed_at
    ])
    |> trim_fields([
      :watch_id,
      :ref,
      :status,
      :mode,
      :project,
      :session_type,
      :session_kind,
      :goal,
      :success_pattern,
      :blocker_pattern,
      :prompt,
      :last_summary,
      :result_summary
    ])
    |> validate_required([:watch_id, :ref, :status, :mode])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:mode, @modes)
    |> unique_constraint(:watch_id)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
