defmodule JX.DelegatedExecution.Assignment do
  @moduledoc """
  Durable delegated safe-action assignment.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(created claimed started progressed completed failed expired)

  @type t :: %__MODULE__{}

  schema "delegated_assignments" do
    field(:assignment_id, :string)
    field(:action_id, :string)
    field(:approval_id, :string, default: "")
    field(:workspace_id, :string, default: "")
    field(:safe_action_kind, :string, default: "")
    field(:status, :string, default: "created")
    field(:active_claim_key, :string)
    field(:claimant_agent_id, :string, default: "")
    field(:runner_id, :string, default: "")
    field(:session_id, :string, default: "")
    field(:lease_id, :string, default: "")
    field(:correlation_id, :string, default: "")
    field(:required_capabilities, :string, default: "[]")
    field(:summary, :string, default: "")
    field(:metadata, :string, default: "{}")
    field(:claimed_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:last_report_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def active_statuses, do: ~w(created claimed started progressed)

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [
      :assignment_id,
      :action_id,
      :approval_id,
      :workspace_id,
      :safe_action_kind,
      :status,
      :active_claim_key,
      :claimant_agent_id,
      :runner_id,
      :session_id,
      :lease_id,
      :correlation_id,
      :required_capabilities,
      :summary,
      :metadata,
      :claimed_at,
      :started_at,
      :last_report_at,
      :completed_at,
      :expires_at
    ])
    |> trim_fields([
      :assignment_id,
      :action_id,
      :approval_id,
      :workspace_id,
      :safe_action_kind,
      :status,
      :active_claim_key,
      :claimant_agent_id,
      :runner_id,
      :session_id,
      :lease_id,
      :correlation_id,
      :required_capabilities,
      :summary,
      :metadata
    ])
    |> validate_required([
      :assignment_id,
      :action_id,
      :status,
      :correlation_id,
      :required_capabilities,
      :metadata
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:assignment_id)
    |> unique_constraint(:active_claim_key)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(to_string(value))
end
