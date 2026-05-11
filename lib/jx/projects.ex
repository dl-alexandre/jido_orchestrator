defmodule JX.Projects do
  @moduledoc """
  Project registry operations.
  """

  import Ecto.Query

  alias JX.Hosts
  alias JX.Projects.Project
  alias JX.Repo

  def list_projects do
    Project
    |> Repo.all()
    |> Repo.preload(:host)
    |> Enum.sort_by(& &1.name)
  end

  def upsert_project(%{host_name: host_name} = attrs) when is_binary(host_name) do
    with %{} = host <- Hosts.get_host_by_name(host_name) do
      project_attrs =
        attrs
        |> Map.delete(:host_name)
        |> Map.put(:host_id, host.id)

      project =
        Repo.get_by(Project,
          name: Map.fetch!(project_attrs, :name),
          host_id: Map.fetch!(project_attrs, :host_id)
        ) || %Project{}

      project
      |> Project.changeset(project_attrs)
      |> Repo.insert_or_update()
    else
      nil -> {:error, :host_not_found}
    end
  end

  def upsert_project(_attrs), do: {:error, :host_not_found}

  def get_project_by_name(name) do
    name
    |> list_projects_by_name()
    |> List.first()
  end

  def get_project_by_name(name, host_name) do
    with %{} = host <- Hosts.get_host_by_name(host_name),
         %{} = project <- Repo.get_by(Project, name: name, host_id: host.id) do
      Repo.preload(project, :host)
    else
      _missing -> nil
    end
  end

  def list_projects_by_name(name) do
    Project
    |> where([project], project.name == ^name)
    |> Repo.all()
    |> Repo.preload(:host)
    |> Enum.sort_by(fn project -> {project.host.name, project.repo_path} end)
  end
end
