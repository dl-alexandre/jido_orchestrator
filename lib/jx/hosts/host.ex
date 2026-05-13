defmodule JX.Hosts.Host do
  @moduledoc """
  Registered execution host capable of running durable worktree sessions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @transports ~w(ssh local)

  @type t :: %__MODULE__{}

  schema "hosts" do
    field(:name, :string)
    field(:transport, :string, default: "ssh")
    field(:ssh_target, :string)
    field(:workspace_path, :string)

    # Operator-set ceiling on concurrent worktree sessions.
    # When set, this overrides the hardware-probed formula in JX.HostCapacity.
    field(:capacity_limit, :integer)

    has_many(:projects, JX.Projects.Project)
    has_many(:directives, JX.Directives.Directive)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(host, attrs) do
    host
    |> cast(attrs, [:name, :transport, :ssh_target, :workspace_path, :capacity_limit])
    |> update_change(:name, &trim/1)
    |> update_change(:transport, &trim/1)
    |> update_change(:ssh_target, &trim/1)
    |> update_change(:workspace_path, &clean_path/1)
    |> normalize_local_target()
    |> validate_required([:name, :transport, :workspace_path])
    |> validate_number(:capacity_limit, greater_than: 0)
    |> validate_inclusion(:transport, @transports)
    |> validate_ssh_target()
    |> validate_ssh_target_shape()
    |> unique_constraint(:name)
  end

  def local?(%__MODULE__{transport: "local"}), do: true
  def local?(_host), do: false

  defp normalize_local_target(changeset) do
    case get_field(changeset, :transport) do
      "local" -> put_change(changeset, :ssh_target, "")
      _transport -> changeset
    end
  end

  defp validate_ssh_target(changeset) do
    case get_field(changeset, :transport) do
      "local" -> changeset
      _transport -> validate_required(changeset, [:ssh_target])
    end
  end

  defp validate_ssh_target_shape(changeset) do
    validate_change(changeset, :ssh_target, fn :ssh_target, target ->
      target = to_string(target || "")

      cond do
        get_field(changeset, :transport) == "local" ->
          []

        String.starts_with?(target, "-") ->
          [ssh_target: "must not start with -"]

        String.match?(target, ~r/\s/) ->
          [ssh_target: "must not contain whitespace"]

        true ->
          []
      end
    end)
  end

  defp clean_path(nil), do: nil

  defp clean_path(path) do
    path
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
