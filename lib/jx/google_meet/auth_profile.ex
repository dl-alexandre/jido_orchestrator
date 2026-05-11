defmodule JX.GoogleMeet.AuthProfile do
  @moduledoc """
  Personal Google OAuth profile for the Google Meet participant plugin.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(configured pending authenticated error)

  @type t :: %__MODULE__{}

  schema "google_meet_auth_profiles" do
    field(:profile_id, :string)
    field(:name, :string)
    field(:email, :string, default: "")
    field(:status, :string, default: "configured")
    field(:client_id, :string, default: "")
    field(:client_secret_env, :string, default: "")
    field(:redirect_uri, :string, default: "")
    field(:scopes, :string, default: "[]")
    field(:token, :string, default: "{}")
    field(:pending_auth, :string, default: "{}")
    field(:last_error, :string, default: "")
    field(:authenticated_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :profile_id,
      :name,
      :email,
      :status,
      :client_id,
      :client_secret_env,
      :redirect_uri,
      :scopes,
      :token,
      :pending_auth,
      :last_error,
      :authenticated_at
    ])
    |> trim_fields([
      :profile_id,
      :name,
      :email,
      :status,
      :client_id,
      :client_secret_env,
      :redirect_uri,
      :scopes,
      :token,
      :pending_auth,
      :last_error
    ])
    |> validate_required([:profile_id, :name, :status, :client_id, :redirect_uri, :scopes])
    |> validate_inclusion(:status, @statuses)
    |> validate_format(:redirect_uri, ~r/^https?:\/\//)
    |> unique_constraint(:profile_id)
    |> unique_constraint(:name)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(to_string(value))
end
