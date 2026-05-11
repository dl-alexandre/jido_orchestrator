defmodule JX.DelegatedExecution.RunnerReport do
  @moduledoc """
  Append-only remote runner session report.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(
    runner.registered
    runner.heartbeat
    runner_session.created
    runner_session.reconnected
    runner_session.claimed
    runner_session.started
    runner_session.heartbeat
    runner_session.progressed
    runner_session.completed
    runner_session.failed
    runner_session.expired
    runner_session.logs
    runner_session.attach
  )

  @type t :: %__MODULE__{}

  schema "delegated_runner_reports" do
    field(:report_id, :string)
    field(:session_id, :string, default: "")
    field(:runner_id, :string)
    field(:agent_id, :string, default: "")
    field(:assignment_id, :string, default: "")
    field(:workspace_id, :string, default: "")
    field(:action_id, :string, default: "")
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
      :session_id,
      :runner_id,
      :agent_id,
      :assignment_id,
      :workspace_id,
      :action_id,
      :kind,
      :status,
      :correlation_id,
      :fingerprint,
      :summary,
      :payload
    ])
    |> trim_fields([
      :report_id,
      :session_id,
      :runner_id,
      :agent_id,
      :assignment_id,
      :workspace_id,
      :action_id,
      :kind,
      :status,
      :correlation_id,
      :fingerprint,
      :summary,
      :payload
    ])
    |> validate_required([:report_id, :runner_id, :kind, :fingerprint, :payload])
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
