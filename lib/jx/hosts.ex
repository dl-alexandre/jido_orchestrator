defmodule JX.Hosts do
  @moduledoc """
  Host registry operations.
  """

  import Ecto.Query

  alias JX.Hosts.Host
  alias JX.Repo

  def upsert_host(%{name: name} = attrs) when is_binary(name) do
    case Repo.get_by(Host, name: name) do
      nil -> %Host{}
      host -> host
    end
    |> Host.changeset(attrs)
    |> Repo.insert_or_update()
  end

  def upsert_host(attrs) do
    %Host{}
    |> Host.changeset(attrs)
    |> Repo.insert()
  end

  def list_hosts do
    Host
    |> order_by([host], asc: host.name)
    |> Repo.all()
  end

  def set_capacity_limit(host_name, limit) when is_integer(limit) and limit > 0 do
    case get_host_by_name(host_name) do
      nil ->
        {:error, :host_not_found}

      host ->
        host
        |> Host.changeset(%{capacity_limit: limit})
        |> Repo.update()
    end
  end

  def get_host_by_name(name), do: Repo.get_by(Host, name: name)

  def get_host_with_projects_by_name(name) do
    case get_host_by_name(name) do
      nil -> nil
      host -> Repo.preload(host, :projects)
    end
  end
end
