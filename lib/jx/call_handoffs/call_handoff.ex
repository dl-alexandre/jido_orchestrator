defmodule JX.CallHandoffs.CallHandoff do
  @moduledoc """
  Durable handoff captured from a call, meeting, or realtime conversation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(open applied closed)
  @surfaces ~w(call phone meet talk chat)

  @type t :: %__MODULE__{}

  schema "call_handoffs" do
    field(:handoff_id, :string)
    field(:surface, :string, default: "call")
    field(:status, :string, default: "open")
    field(:project, :string, default: "")
    field(:ref, :string, default: "")
    field(:title, :string, default: "")
    field(:summary, :string, default: "")
    field(:operator_input, :string, default: "")
    field(:decisions, :string, default: "[]")
    field(:follow_ups, :string, default: "[]")
    field(:brief_snapshot, :string, default: "{}")
    field(:payload, :string, default: "{}")
    field(:closed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def surfaces, do: @surfaces

  def changeset(handoff, attrs) do
    handoff
    |> cast(attrs, [
      :handoff_id,
      :surface,
      :status,
      :project,
      :ref,
      :title,
      :summary,
      :operator_input,
      :decisions,
      :follow_ups,
      :brief_snapshot,
      :payload,
      :closed_at
    ])
    |> trim_fields([
      :handoff_id,
      :surface,
      :status,
      :project,
      :ref,
      :title,
      :summary,
      :operator_input,
      :decisions,
      :follow_ups,
      :brief_snapshot,
      :payload
    ])
    |> validate_required([
      :handoff_id,
      :surface,
      :status,
      :decisions,
      :follow_ups,
      :brief_snapshot,
      :payload
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:surface, @surfaces)
    |> unique_constraint(:handoff_id)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(to_string(value))
end
