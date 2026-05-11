defmodule JX.DelegatedExecution.RunnerSession do
  @moduledoc """
  Tmux-backed remote runner session bound to one delegated assignment.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(created claimed running progressed completed failed stale expired ended)

  @type t :: %__MODULE__{}

  schema "delegated_runner_sessions" do
    field(:session_id, :string)
    field(:runner_id, :string)
    field(:agent_id, :string, default: "")
    field(:assignment_id, :string, default: "")
    field(:workspace_id, :string, default: "")
    field(:action_id, :string, default: "")
    field(:approval_id, :string, default: "")
    field(:status, :string, default: "created")
    field(:active_assignment_key, :string)
    field(:correlation_id, :string, default: "")
    field(:tmux_server, :string, default: "")
    field(:tmux_session_name, :string, default: "")
    field(:log_path, :string, default: "")
    field(:last_summary, :string, default: "")
    field(:metadata, :string, default: "{}")
    field(:started_at, :utc_datetime_usec)
    field(:heartbeat_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def active_statuses, do: ~w(created claimed running progressed stale)

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :session_id,
      :runner_id,
      :agent_id,
      :assignment_id,
      :workspace_id,
      :action_id,
      :approval_id,
      :status,
      :active_assignment_key,
      :correlation_id,
      :tmux_server,
      :tmux_session_name,
      :log_path,
      :last_summary,
      :metadata,
      :started_at,
      :heartbeat_at,
      :ended_at,
      :expires_at
    ])
    |> trim_fields([
      :session_id,
      :runner_id,
      :agent_id,
      :assignment_id,
      :workspace_id,
      :action_id,
      :approval_id,
      :status,
      :active_assignment_key,
      :correlation_id,
      :tmux_server,
      :tmux_session_name,
      :log_path,
      :last_summary,
      :metadata
    ])
    |> validate_required([
      :session_id,
      :runner_id,
      :agent_id,
      :assignment_id,
      :status,
      :correlation_id,
      :metadata
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:session_id)
    |> unique_constraint(:active_assignment_key)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(to_string(value))
end
