defmodule JX.OrchestrationActions.OrchestrationAction do
  @moduledoc """
  Durable queued/planned action emitted by orchestration.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(planned queued executed skipped error cancelled)
  @outcomes ~w(helpful ignored blocked superseded failed)
  @safeties ~w(safe gated manual inspect)

  @type t :: %__MODULE__{}

  schema "orchestration_actions" do
    field(:action_id, :string)
    field(:queue_key, :string)
    field(:requested, :string, default: "")
    field(:source, :string, default: "")
    field(:recommendation_id, :string, default: "")
    field(:action, :string, default: "")
    field(:safety, :string, default: "")
    field(:ref, :string, default: "")
    field(:target, :string, default: "")
    field(:status, :string, default: "planned")
    field(:reason, :string, default: "")
    field(:error, :string, default: "")
    field(:result_summary, :string, default: "")
    field(:outcome, :string, default: "")
    field(:outcome_reason, :string, default: "")
    field(:payload, :string, default: "{}")
    field(:scheduled_at, :utc_datetime_usec)
    field(:executed_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def outcomes, do: @outcomes
  def safeties, do: @safeties

  def changeset(action, attrs) do
    action
    |> cast(attrs, [
      :action_id,
      :queue_key,
      :requested,
      :source,
      :recommendation_id,
      :action,
      :safety,
      :ref,
      :target,
      :status,
      :reason,
      :error,
      :result_summary,
      :outcome,
      :outcome_reason,
      :payload,
      :scheduled_at,
      :executed_at,
      :completed_at
    ])
    |> trim_fields([
      :action_id,
      :queue_key,
      :requested,
      :source,
      :recommendation_id,
      :action,
      :safety,
      :ref,
      :target,
      :status,
      :reason,
      :error,
      :result_summary,
      :outcome,
      :outcome_reason
    ])
    |> validate_required([:action_id, :queue_key, :requested, :source, :status, :payload])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:outcome, [""] ++ @outcomes)
    |> validate_inclusion(:safety, [""] ++ @safeties)
    |> unique_constraint(:action_id)
    |> unique_constraint(:queue_key)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
