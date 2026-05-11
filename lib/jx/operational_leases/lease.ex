defmodule JX.OperationalLeases.Lease do
  @moduledoc """
  Current durable lease/claim for an operational resource.

  The append-only lease evidence is stored in `JX.OperationalEvents.Event`; this
  table prevents conflicting active ownership.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @resource_types ~w(approval action workspace)
  @statuses ~w(active released expired reassigned)

  @type t :: %__MODULE__{}

  schema "operational_leases" do
    field(:lease_id, :string)
    field(:resource_type, :string)
    field(:resource_id, :string)
    field(:active_key, :string)
    field(:owner, :string)
    field(:status, :string, default: "active")
    field(:correlation_id, :string, default: "")
    field(:reason, :string, default: "")
    field(:metadata, :string, default: "{}")
    field(:acquired_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:released_at, :utc_datetime_usec)
    field(:reassigned_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def resource_types, do: @resource_types
  def statuses, do: @statuses

  def changeset(lease, attrs) do
    lease
    |> cast(attrs, [
      :lease_id,
      :resource_type,
      :resource_id,
      :active_key,
      :owner,
      :status,
      :correlation_id,
      :reason,
      :metadata,
      :acquired_at,
      :expires_at,
      :released_at,
      :reassigned_at
    ])
    |> trim_fields([
      :lease_id,
      :resource_type,
      :resource_id,
      :active_key,
      :owner,
      :status,
      :correlation_id,
      :reason,
      :metadata
    ])
    |> validate_required([
      :lease_id,
      :resource_type,
      :resource_id,
      :owner,
      :status,
      :correlation_id,
      :metadata
    ])
    |> validate_inclusion(:resource_type, @resource_types)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:lease_id)
    |> unique_constraint(:active_key)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(to_string(value))
end
