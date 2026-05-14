defmodule JX.Projects.Project do
  @moduledoc """
  A project repository registered on a remote host.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias JX.Hosts.Host
  alias JX.IDs

  @type t :: %__MODULE__{}

  # Named capacity profiles shipped with jx.
  # Each describes the per-slot resource footprint of that project type.
  @profiles %{
    "elixir-phoenix" => %{name: "elixir-phoenix", ram_mb_per_slot: 3_072, disk_mb_per_slot: 2_048, cpu_cores_per_slot: 0.4},
    "rails"          => %{name: "rails",           ram_mb_per_slot: 2_048, disk_mb_per_slot: 1_536, cpu_cores_per_slot: 0.5},
    "nodejs"         => %{name: "nodejs",           ram_mb_per_slot: 1_024, disk_mb_per_slot: 1_024, cpu_cores_per_slot: 0.3},
    "go"             => %{name: "go",               ram_mb_per_slot: 768,   disk_mb_per_slot: 1_024, cpu_cores_per_slot: 0.6},
    "python-ml"      => %{name: "python-ml",        ram_mb_per_slot: 6_144, disk_mb_per_slot: 4_096, cpu_cores_per_slot: 0.5}
  }

  def profiles, do: @profiles
  def profile_names, do: Map.keys(@profiles)

  def resolve_profile(nil), do: nil
  def resolve_profile(name), do: Map.get(@profiles, name)

  schema "projects" do
    field(:name, :string)
    field(:slug, :string)
    field(:repo_path, :string)

    # Named capacity preset for this project type.
    # nil means fall back to the host's default profile.
    field(:capacity_profile, :string)

    belongs_to(:host, Host)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :repo_path, :host_id, :capacity_profile])
    |> update_change(:name, &trim/1)
    |> update_change(:repo_path, &clean_path/1)
    |> put_slug()
    |> validate_required([:name, :slug, :repo_path, :host_id])
    |> validate_inclusion(:capacity_profile, Map.keys(@profiles), allow_nil: true)
    |> assoc_constraint(:host)
    |> unique_constraint(:name, name: :projects_host_id_name_index)
    |> unique_constraint(:slug, name: :projects_host_id_slug_index)
  end

  defp put_slug(changeset) do
    case get_field(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :slug, IDs.slug(name))
    end
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
