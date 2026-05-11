defmodule JX.OperationalEvents.Event do
  @moduledoc """
  Append-only operational evidence event.

  These events normalize approvals, safe actions, DevIDE snapshots, leases, and
  operator decisions into one causally ordered stream for queue reducers and
  timeline reconstruction.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias JX.MonitorEvents.Event, as: MonitorEvent

  @entity_types ~w(workspace approval action lease agent runner assignment runner_session assignment_report runner_report runtime_environment portfolio_risk devide_run operator_decision)

  @type t :: %__MODULE__{}

  schema "operational_events" do
    field(:event_id, :string)
    field(:correlation_id, :string, default: "")
    field(:source, :string, default: "")
    field(:kind, :string)
    field(:entity_type, :string, default: "")
    field(:entity_id, :string, default: "")
    field(:workspace_id, :string, default: "")
    field(:approval_id, :string, default: "")
    field(:action_id, :string, default: "")
    field(:lease_id, :string, default: "")
    field(:owner, :string, default: "")
    field(:severity, :string, default: "info")
    field(:summary, :string, default: "")
    field(:payload, :string, default: "{}")
    field(:caused_by_event_id, :string, default: "")

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def entity_types, do: @entity_types

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_id,
      :correlation_id,
      :source,
      :kind,
      :entity_type,
      :entity_id,
      :workspace_id,
      :approval_id,
      :action_id,
      :lease_id,
      :owner,
      :severity,
      :summary,
      :payload,
      :caused_by_event_id
    ])
    |> trim_fields([
      :event_id,
      :correlation_id,
      :source,
      :kind,
      :entity_type,
      :entity_id,
      :workspace_id,
      :approval_id,
      :action_id,
      :lease_id,
      :owner,
      :severity,
      :summary,
      :caused_by_event_id
    ])
    |> validate_required([:event_id, :correlation_id, :kind, :entity_type, :entity_id, :payload])
    |> validate_inclusion(:entity_type, @entity_types)
    |> validate_inclusion(:severity, MonitorEvent.severities())
    |> unique_constraint(:event_id)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(to_string(value))
end
