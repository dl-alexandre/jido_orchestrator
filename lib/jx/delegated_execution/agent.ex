defmodule JX.DelegatedExecution.Agent do
  @moduledoc """
  Durable identity and liveness record for a delegated execution agent.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(idle busy stale disabled)

  @type t :: %__MODULE__{}

  schema "delegated_agents" do
    field(:agent_id, :string)
    field(:name, :string, default: "")
    field(:status, :string, default: "idle")
    field(:capabilities, :string, default: "[]")
    field(:workspace_affinity, :string, default: "[]")
    field(:heartbeat_ttl_seconds, :integer, default: 120)
    field(:last_heartbeat_at, :utc_datetime_usec)
    field(:metadata, :string, default: "{}")

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :agent_id,
      :name,
      :status,
      :capabilities,
      :workspace_affinity,
      :heartbeat_ttl_seconds,
      :last_heartbeat_at,
      :metadata
    ])
    |> trim_fields([:agent_id, :name, :status, :capabilities, :workspace_affinity, :metadata])
    |> validate_required([
      :agent_id,
      :status,
      :capabilities,
      :workspace_affinity,
      :heartbeat_ttl_seconds,
      :metadata
    ])
    |> validate_number(:heartbeat_ttl_seconds, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:agent_id)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(to_string(value))
end
