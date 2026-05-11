defmodule JX.SessionProfiles.OperatorProfile do
  @moduledoc """
  Operator profile used to tune orchestration decisions and handoffs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "operator_profiles" do
    field(:profile_key, :string, default: "default")
    field(:name, :string, default: "")
    field(:preferences, :string, default: "")
    field(:working_style, :string, default: "")
    field(:escalation_policy, :string, default: "")
    field(:notes, :string, default: "")

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :profile_key,
      :name,
      :preferences,
      :working_style,
      :escalation_policy,
      :notes
    ])
    |> trim_fields([
      :profile_key,
      :name,
      :preferences,
      :working_style,
      :escalation_policy,
      :notes
    ])
    |> validate_required([:profile_key])
    |> unique_constraint(:profile_key)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
