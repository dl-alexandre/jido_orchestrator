defmodule JX.OperationExecutions.OperationExecution do
  @moduledoc """
  Durable audit record for an operator action execution attempt.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(executed skipped error)
  @safeties ~w(safe gated manual)

  @type t :: %__MODULE__{}

  schema "operation_executions" do
    field(:execution_id, :string)
    field(:requested, :string, default: "")
    field(:recommendation_id, :string)
    field(:action, :string, default: "")
    field(:safety, :string, default: "")
    field(:ref, :string, default: "")
    field(:target, :string, default: "")
    field(:status, :string)
    field(:reason, :string, default: "")
    field(:error, :string, default: "")
    field(:result_summary, :string, default: "")
    field(:result_snapshot, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(execution, attrs) do
    execution
    |> cast(attrs, [
      :execution_id,
      :requested,
      :recommendation_id,
      :action,
      :safety,
      :ref,
      :target,
      :status,
      :reason,
      :error,
      :result_summary,
      :result_snapshot
    ])
    |> update_change(:requested, &trim/1)
    |> update_change(:recommendation_id, &trim/1)
    |> update_change(:action, &trim/1)
    |> update_change(:safety, &trim/1)
    |> update_change(:ref, &trim/1)
    |> update_change(:target, &trim/1)
    |> update_change(:status, &trim/1)
    |> update_change(:reason, &trim/1)
    |> update_change(:error, &trim/1)
    |> update_change(:result_summary, &trim/1)
    |> validate_required([
      :execution_id,
      :requested,
      :recommendation_id,
      :status,
      :result_snapshot
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:safety, [""] ++ @safeties)
    |> unique_constraint(:execution_id)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
