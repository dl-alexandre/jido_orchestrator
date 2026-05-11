defmodule JX.DelegatedExecution.Report do
  @moduledoc """
  Append-only delegated assignment execution report.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(
    assignment.created
    assignment.claimed
    assignment.started
    assignment.progressed
    assignment.completed
    assignment.failed
    assignment.expired
    agent.registered
    agent.heartbeat
  )

  @type t :: %__MODULE__{}

  schema "delegated_assignment_reports" do
    field(:report_id, :string)
    field(:assignment_id, :string)
    field(:agent_id, :string)
    field(:action_id, :string, default: "")
    field(:workspace_id, :string, default: "")
    field(:kind, :string)
    field(:status, :string, default: "")
    field(:correlation_id, :string, default: "")
    field(:fingerprint, :string)
    field(:summary, :string, default: "")
    field(:payload, :string, default: "{}")

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def kinds, do: @kinds

  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :report_id,
      :assignment_id,
      :agent_id,
      :action_id,
      :workspace_id,
      :kind,
      :status,
      :correlation_id,
      :fingerprint,
      :summary,
      :payload
    ])
    |> trim_fields([
      :report_id,
      :assignment_id,
      :agent_id,
      :action_id,
      :workspace_id,
      :kind,
      :status,
      :correlation_id,
      :fingerprint,
      :summary,
      :payload
    ])
    |> validate_required([:report_id, :assignment_id, :agent_id, :kind, :fingerprint, :payload])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:report_id)
    |> unique_constraint(:fingerprint)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(to_string(value))
end
