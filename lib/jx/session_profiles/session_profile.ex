defmodule JX.SessionProfiles.SessionProfile do
  @moduledoc """
  Operator-maintained planning profile for a discovered session.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @prompt_statuses ~w(none draft ready sent blocked)

  @type t :: %__MODULE__{}

  schema "session_profiles" do
    field(:ref, :string)
    field(:summary, :string, default: "")
    field(:objective, :string, default: "")
    field(:expected_completion, :string, default: "")
    field(:next_prompt, :string, default: "")
    field(:prompt_status, :string, default: "none")
    field(:strategy, :string, default: "")
    field(:notes, :string, default: "")
    field(:owner, :string, default: "")
    field(:risk_level, :string, default: "normal")
    field(:lifecycle_status, :string, default: "active")
    field(:current_hypothesis, :string, default: "")
    field(:last_evidence, :string, default: "")
    field(:stale_after_seconds, :integer)
    field(:last_seen_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def prompt_statuses, do: @prompt_statuses

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :ref,
      :summary,
      :objective,
      :expected_completion,
      :next_prompt,
      :prompt_status,
      :strategy,
      :notes,
      :owner,
      :risk_level,
      :lifecycle_status,
      :current_hypothesis,
      :last_evidence,
      :stale_after_seconds,
      :last_seen_at
    ])
    |> trim_fields([
      :ref,
      :summary,
      :objective,
      :expected_completion,
      :next_prompt,
      :prompt_status,
      :strategy,
      :notes,
      :owner,
      :risk_level,
      :lifecycle_status,
      :current_hypothesis,
      :last_evidence
    ])
    |> validate_required([:ref, :prompt_status])
    |> validate_inclusion(:prompt_status, @prompt_statuses)
    |> validate_inclusion(:risk_level, ["low", "normal", "high", "blocked"])
    |> validate_inclusion(:lifecycle_status, ["active", "parked", "done", "blocked"])
    |> validate_number(:stale_after_seconds, greater_than: 0)
    |> unique_constraint(:ref)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
