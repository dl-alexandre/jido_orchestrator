defmodule JX.CiWatches.CiWatch do
  @moduledoc """
  Durable GitHub Actions PR watch for background orchestration.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active passed failed cancelled superseded)
  @modes ~w(notify hold prompt)

  @type t :: %__MODULE__{}

  schema "ci_watches" do
    field(:watch_id, :string)
    field(:repo, :string)
    field(:pr_number, :integer)
    field(:ref, :string, default: "")
    field(:project, :string, default: "")
    field(:status, :string, default: "active")
    field(:mode, :string, default: "notify")
    field(:goal, :string, default: "")
    field(:success_prompt, :string, default: "")
    field(:failure_prompt, :string, default: "")
    field(:head_sha, :string, default: "")
    field(:last_head_sha, :string, default: "")
    field(:last_overall, :string, default: "")
    field(:last_summary, :string, default: "")
    field(:last_digest, :string, default: "{}")
    field(:last_checked_at, :utc_datetime_usec)
    field(:last_head_checked_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def modes, do: @modes

  def changeset(watch, attrs) do
    watch
    |> cast(attrs, [
      :watch_id,
      :repo,
      :pr_number,
      :ref,
      :project,
      :status,
      :mode,
      :goal,
      :success_prompt,
      :failure_prompt,
      :head_sha,
      :last_head_sha,
      :last_overall,
      :last_summary,
      :last_digest,
      :last_checked_at,
      :last_head_checked_at,
      :completed_at
    ])
    |> trim_fields([
      :watch_id,
      :repo,
      :ref,
      :project,
      :status,
      :mode,
      :goal,
      :success_prompt,
      :failure_prompt,
      :head_sha,
      :last_head_sha,
      :last_overall,
      :last_summary,
      :last_digest
    ])
    |> validate_required([:watch_id, :repo, :pr_number, :status, :mode])
    |> validate_number(:pr_number, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:mode, @modes)
    |> unique_constraint(:watch_id)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(to_string(value))
end
