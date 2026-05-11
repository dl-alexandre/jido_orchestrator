defmodule JX.SafeActions.ExecutionEvent do
  @moduledoc """
  Immutable audit event for approval-gated safe action lifecycle changes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(
    proposed
    dry_run_viewed
    execute_attempted
    execute_denied
    executed
    approval_ack_attempted
    approval_acknowledged
  )

  @outcomes ~w(
    proposed
    dry_run_viewed
    execute_attempted
    success
    devide_failure
    network_failure
    policy_denied
    malformed_response
    approval_ack_failure
    approval_acknowledged
    confirmation_required
    replay_denied
  )

  @type t :: %__MODULE__{}

  schema "safe_action_events" do
    field(:event_id, :string)
    field(:correlation_id, :string, default: "")
    field(:action_id, :string)
    field(:approval_id, :string, default: "")
    field(:workspace_id, :string, default: "")
    field(:command_id, :string, default: "")
    field(:kind, :string)
    field(:outcome, :string, default: "")
    field(:reason, :string, default: "")
    field(:payload, :string, default: "{}")

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def kinds, do: @kinds
  def outcomes, do: @outcomes

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_id,
      :correlation_id,
      :action_id,
      :approval_id,
      :workspace_id,
      :command_id,
      :kind,
      :outcome,
      :reason,
      :payload
    ])
    |> trim_fields([
      :event_id,
      :correlation_id,
      :action_id,
      :approval_id,
      :workspace_id,
      :command_id,
      :kind,
      :outcome,
      :reason
    ])
    |> validate_required([:event_id, :correlation_id, :action_id, :kind, :outcome, :payload])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:outcome, @outcomes)
    |> unique_constraint(:event_id)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
