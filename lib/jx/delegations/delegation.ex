defmodule JX.Delegations.Delegation do
  @moduledoc """
  Durable packet of work delegated from the foreground orchestrator to a worker.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(queued running blocked completed cancelled failed)
  @agent_kinds ~w(worker explorer verifier codex claude opencode human)
  @integration_statuses ~w(pending accepted revision_requested rejected held)

  @type t :: %__MODULE__{}

  schema "delegations" do
    field(:delegation_id, :string)
    field(:status, :string, default: "queued")
    field(:priority, :integer, default: 0)
    field(:project, :string, default: "")
    field(:ref, :string, default: "")
    field(:source, :string, default: "foreground")
    field(:owner, :string, default: "")
    field(:agent_kind, :string, default: "worker")
    field(:title, :string, default: "")
    field(:brief, :string, default: "")
    field(:context, :string, default: "[]")
    field(:constraints, :string, default: "[]")
    field(:acceptance, :string, default: "[]")
    field(:verification, :string, default: "[]")
    field(:write_paths, :string, default: "[]")
    field(:forbidden_paths, :string, default: "[]")
    field(:worker_summary, :string, default: "")
    field(:lint_warnings, :string, default: "[]")
    field(:evidence, :string, default: "[]")
    field(:residual_risks, :string, default: "[]")
    field(:artifacts, :string, default: "[]")
    field(:integration_status, :string, default: "pending")
    field(:integration_summary, :string, default: "")
    field(:reviewed_by, :string, default: "")
    field(:payload, :string, default: "{}")
    field(:claimed_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:reviewed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def agent_kinds, do: @agent_kinds
  def integration_statuses, do: @integration_statuses

  def changeset(delegation, attrs) do
    delegation
    |> cast(attrs, [
      :delegation_id,
      :status,
      :priority,
      :project,
      :ref,
      :source,
      :owner,
      :agent_kind,
      :title,
      :brief,
      :context,
      :constraints,
      :acceptance,
      :verification,
      :write_paths,
      :forbidden_paths,
      :worker_summary,
      :lint_warnings,
      :evidence,
      :residual_risks,
      :artifacts,
      :integration_status,
      :integration_summary,
      :reviewed_by,
      :payload,
      :claimed_at,
      :completed_at,
      :reviewed_at
    ])
    |> trim_fields([
      :delegation_id,
      :status,
      :project,
      :ref,
      :source,
      :owner,
      :agent_kind,
      :title,
      :brief,
      :context,
      :constraints,
      :acceptance,
      :verification,
      :write_paths,
      :forbidden_paths,
      :worker_summary,
      :lint_warnings,
      :evidence,
      :residual_risks,
      :artifacts,
      :integration_status,
      :integration_summary,
      :reviewed_by,
      :payload
    ])
    |> validate_required([
      :delegation_id,
      :status,
      :priority,
      :source,
      :agent_kind,
      :title,
      :brief,
      :context,
      :constraints,
      :acceptance,
      :verification,
      :write_paths,
      :forbidden_paths,
      :lint_warnings,
      :evidence,
      :residual_risks,
      :artifacts,
      :integration_status,
      :payload
    ])
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:agent_kind, @agent_kinds)
    |> validate_inclusion(:integration_status, @integration_statuses)
    |> unique_constraint(:delegation_id)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(to_string(value))
end
