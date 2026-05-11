defmodule JX.Projects.Project do
  @moduledoc """
  A project repository registered on a remote host.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias JX.Hosts.Host
  alias JX.IDs

  @type t :: %__MODULE__{}

  schema "projects" do
    field(:name, :string)
    field(:slug, :string)
    field(:repo_path, :string)

    belongs_to(:host, Host)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :repo_path, :host_id])
    |> update_change(:name, &trim/1)
    |> update_change(:repo_path, &clean_path/1)
    |> put_slug()
    |> validate_required([:name, :slug, :repo_path, :host_id])
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
