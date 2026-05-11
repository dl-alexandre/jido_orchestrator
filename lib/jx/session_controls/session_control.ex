defmodule JX.SessionControls.SessionControl do
  @moduledoc """
  Operator-owned policy for a discovered session ref.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @modes ~w(managed ignored protected)

  @type t :: %__MODULE__{}

  schema "session_controls" do
    field(:ref, :string)
    field(:mode, :string)
    field(:project, :string, default: "")
    field(:note, :string, default: "")
    field(:host, :string, default: "")
    field(:type, :string, default: "")
    field(:kind, :string, default: "")
    field(:ssh_target, :string, default: "")
    field(:tmux_server, :string, default: "")
    field(:session_name, :string, default: "")
    field(:window, :integer)
    field(:pane, :integer)
    field(:pid, :integer)
    field(:current_path, :string, default: "")
    field(:title, :string, default: "")
    field(:last_seen_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def modes, do: @modes

  def changeset(control, attrs) do
    control
    |> cast(attrs, [
      :ref,
      :mode,
      :project,
      :note,
      :host,
      :type,
      :kind,
      :ssh_target,
      :tmux_server,
      :session_name,
      :window,
      :pane,
      :pid,
      :current_path,
      :title,
      :last_seen_at
    ])
    |> trim_fields([
      :ref,
      :mode,
      :project,
      :note,
      :host,
      :type,
      :kind,
      :ssh_target,
      :tmux_server,
      :session_name,
      :current_path,
      :title
    ])
    |> validate_required([:ref, :mode])
    |> validate_inclusion(:mode, @modes)
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
