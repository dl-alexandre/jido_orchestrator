defmodule JX.ResourceOwnerships.Resource do
  @moduledoc """
  Durable ownership record for project-created infrastructure resources.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @resource_types ~w(tmux_session temp_path worktree_path task_dir log_path)
  @cleanup_policies ~w(manual kill_tmux_session rm_rf exempt)
  @states ~w(created live stale missing ended exempt unknown)

  @type t :: %__MODULE__{}

  schema "resource_ownerships" do
    field(:resource_id, :string)
    field(:owner_type, :string, default: "project")
    field(:owner_project, :string)
    field(:assignment_id, :string, default: "")
    field(:execution_id, :string, default: "")
    field(:resource_type, :string)
    field(:resource_name, :string)
    field(:resource_path, :string, default: "")
    field(:tmux_server, :string, default: "")
    field(:cleanup_policy, :string)
    field(:state, :string, default: "created")
    field(:reason, :string, default: "")
    field(:metadata, :string, default: "{}")
    field(:created_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def resource_types, do: @resource_types
  def cleanup_policies, do: @cleanup_policies
  def states, do: @states

  def changeset(resource, attrs) do
    resource
    |> cast(attrs, [
      :resource_id,
      :owner_type,
      :owner_project,
      :assignment_id,
      :execution_id,
      :resource_type,
      :resource_name,
      :resource_path,
      :tmux_server,
      :cleanup_policy,
      :state,
      :reason,
      :metadata,
      :created_at,
      :ended_at
    ])
    |> trim_fields([
      :resource_id,
      :owner_type,
      :owner_project,
      :assignment_id,
      :execution_id,
      :resource_type,
      :resource_name,
      :resource_path,
      :tmux_server,
      :cleanup_policy,
      :state,
      :reason,
      :metadata
    ])
    |> validate_required([
      :resource_id,
      :owner_type,
      :owner_project,
      :resource_type,
      :resource_name,
      :cleanup_policy,
      :state,
      :metadata,
      :created_at
    ])
    |> validate_inclusion(:resource_type, @resource_types)
    |> validate_inclusion(:cleanup_policy, @cleanup_policies)
    |> validate_inclusion(:state, @states)
    |> unique_constraint(:resource_id)
    |> unique_constraint([:resource_type, :resource_name, :resource_path])
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(to_string(value))
end
