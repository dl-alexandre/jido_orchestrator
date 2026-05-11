defmodule JX.DelegatedExecution.Runner do
  @moduledoc """
  Durable remote runner identity for delegated execution.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(idle busy stale disabled)

  @type t :: %__MODULE__{}

  schema "delegated_runners" do
    field(:runner_id, :string)
    field(:agent_id, :string)
    field(:host_name, :string, default: "")
    field(:status, :string, default: "idle")
    field(:capabilities, :string, default: "[]")
    field(:workspace_affinity, :string, default: "[]")
    field(:heartbeat_ttl_seconds, :integer, default: 120)
    field(:last_heartbeat_at, :utc_datetime_usec)
    field(:tmux_server, :string, default: "")
    field(:tmux_session_prefix, :string, default: "")
    field(:metadata, :string, default: "{}")

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(runner, attrs) do
    runner
    |> cast(attrs, [
      :runner_id,
      :agent_id,
      :host_name,
      :status,
      :capabilities,
      :workspace_affinity,
      :heartbeat_ttl_seconds,
      :last_heartbeat_at,
      :tmux_server,
      :tmux_session_prefix,
      :metadata
    ])
    |> trim_fields([
      :runner_id,
      :agent_id,
      :host_name,
      :status,
      :capabilities,
      :workspace_affinity,
      :tmux_server,
      :tmux_session_prefix,
      :metadata
    ])
    |> validate_required([
      :runner_id,
      :agent_id,
      :status,
      :capabilities,
      :workspace_affinity,
      :heartbeat_ttl_seconds,
      :metadata
    ])
    |> validate_number(:heartbeat_ttl_seconds, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:runner_id)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(to_string(value))
end
