defmodule JX.RuntimeEnvironments.Environment do
  @moduledoc """
  Durable workspace runtime environment managed by JX.

  A runtime environment represents placement and lifecycle evidence for an
  isolated workspace/worktree. It does not authorize executable work; safe
  action execution remains delegated to DevIDE.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(planned provisioning ready assigned released failed expired)

  @type t :: %__MODULE__{}

  schema "runtime_environments" do
    field(:runtime_id, :string)
    field(:workspace_id, :string, default: "")
    field(:action_id, :string, default: "")
    field(:assignment_id, :string, default: "")
    field(:runner_id, :string, default: "")
    field(:project_name, :string, default: "")
    field(:host_name, :string, default: "")
    field(:repo_path, :string, default: "")
    field(:worktree_path, :string, default: "")
    field(:branch, :string, default: "")
    field(:status, :string, default: "planned")
    field(:capabilities, :string, default: "[]")
    field(:tools, :string, default: "[]")
    field(:os, :string, default: "")
    field(:branch_isolation, :string, default: "worktree")
    field(:concurrency_limit, :integer, default: 1)
    field(:reusable, :boolean, default: true)
    field(:correlation_id, :string, default: "")
    field(:metadata, :string, default: "{}")
    field(:last_error, :string, default: "")
    field(:provisioned_at, :utc_datetime_usec)
    field(:assigned_at, :utc_datetime_usec)
    field(:released_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def active_statuses, do: ~w(planned provisioning ready assigned)

  def changeset(environment, attrs) do
    environment
    |> cast(attrs, [
      :runtime_id,
      :workspace_id,
      :action_id,
      :assignment_id,
      :runner_id,
      :project_name,
      :host_name,
      :repo_path,
      :worktree_path,
      :branch,
      :status,
      :capabilities,
      :tools,
      :os,
      :branch_isolation,
      :concurrency_limit,
      :reusable,
      :correlation_id,
      :metadata,
      :last_error,
      :provisioned_at,
      :assigned_at,
      :released_at,
      :expires_at
    ])
    |> trim_fields([
      :runtime_id,
      :workspace_id,
      :action_id,
      :assignment_id,
      :runner_id,
      :project_name,
      :host_name,
      :repo_path,
      :worktree_path,
      :branch,
      :status,
      :capabilities,
      :tools,
      :os,
      :branch_isolation,
      :correlation_id,
      :metadata,
      :last_error
    ])
    |> validate_required([
      :runtime_id,
      :workspace_id,
      :project_name,
      :host_name,
      :repo_path,
      :worktree_path,
      :branch,
      :status,
      :capabilities,
      :tools,
      :branch_isolation,
      :concurrency_limit,
      :correlation_id,
      :metadata
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:concurrency_limit, greater_than: 0)
    |> unique_constraint(:runtime_id)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(to_string(value))
end
