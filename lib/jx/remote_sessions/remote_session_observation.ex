defmodule JX.RemoteSessions.RemoteSessionObservation do
  @moduledoc """
  Persisted remote tmux session discovered through an existing SSH pane.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "remote_session_observations" do
    field(:local_ref, :string, default: "")
    field(:ssh_target, :string, default: "")
    field(:registered_host, :string, default: "")
    field(:tmux_server, :string)
    field(:session_name, :string)
    field(:created_at, :utc_datetime_usec)
    field(:attached, :integer, default: 0)
    field(:windows, :integer, default: 0)
    field(:current_path, :string, default: "")
    field(:recommendation_id, :string, default: "")
    field(:probe_target, :string, default: "")

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(observation, attrs) do
    observation
    |> cast(attrs, [
      :local_ref,
      :ssh_target,
      :registered_host,
      :tmux_server,
      :session_name,
      :created_at,
      :attached,
      :windows,
      :current_path,
      :recommendation_id,
      :probe_target
    ])
    |> trim_fields([
      :local_ref,
      :ssh_target,
      :registered_host,
      :tmux_server,
      :session_name,
      :current_path,
      :recommendation_id,
      :probe_target
    ])
    |> validate_required([:tmux_server, :session_name])
    |> validate_number(:attached, greater_than_or_equal_to: 0)
    |> validate_number(:windows, greater_than_or_equal_to: 0)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
