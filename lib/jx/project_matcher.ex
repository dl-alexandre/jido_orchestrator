defmodule JX.ProjectMatcher do
  @moduledoc """
  Shared project matching for observed sessions and project-scoped reports.

  Sessions often do not carry an explicit project label. This module keeps the
  fallback path matching consistent across dossier filters and portfolio
  grouping.
  """

  def name_for_profile(profile, registered_projects) do
    first_present([
      get(profile, [:session, :project]),
      get(profile, [:project])
    ]) ||
      matched_project_name(profile_paths(profile), registered_projects) ||
      path_label(first_present(profile_paths(profile)))
  end

  def matches_dossier?(_dossier, nil, _project), do: true
  def matches_dossier?(_dossier, "", _project), do: true

  def matches_dossier?(dossier, project_name, project) do
    explicit =
      first_present([
        get(dossier, [:project]),
        get(dossier, [:session, :project])
      ])

    explicit == project_name or path_matches_project?(dossier_paths(dossier), project)
  end

  def path_matches_project?(paths, projects) when is_list(projects) do
    Enum.any?(projects, &path_matches_project?(paths, &1))
  end

  def path_matches_project?(paths, project) do
    project
    |> project_paths()
    |> Enum.any?(fn root ->
      Enum.any?(paths, &within_path?(&1, root))
    end)
  end

  def project_paths(nil), do: []

  def project_paths(project) do
    repo_path = field(project, :repo_path, "")
    workspace_path = project_workspace_path(project)

    [
      repo_path,
      path_join(workspace_path, repo_path)
    ]
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
  end

  defp matched_project_name(paths, registered_projects) do
    registered_projects
    |> Enum.find(&path_matches_project?(paths, &1))
    |> case do
      nil -> nil
      project -> field(project, :name)
    end
  end

  defp profile_paths(profile) do
    [
      get(profile, [:actual, :repo, :root]),
      get(profile, [:session, :current_path])
    ]
    |> Enum.filter(&present?/1)
  end

  defp dossier_paths(dossier) do
    [
      get(dossier, [:repo, :root]),
      get(dossier, [:actual, :repo, :root]),
      get(dossier, [:current_path]),
      get(dossier, [:session, :current_path])
    ]
    |> Enum.filter(&present?/1)
  end

  defp project_workspace_path(project) do
    first_present([
      get(project, [:host, :workspace_path]),
      field(project, :workspace_path, "")
    ])
  end

  defp path_join(nil, _path), do: ""
  defp path_join("", _path), do: ""
  defp path_join(_base, nil), do: ""
  defp path_join(_base, ""), do: ""

  defp path_join(base, path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(base, path)
    end
  end

  defp within_path?(path, root) when is_binary(path) and is_binary(root) do
    path = normalize_path(path)
    root = normalize_path(root)

    path == root or String.starts_with?(path, root <> "/")
  end

  defp within_path?(_path, _root), do: false

  defp normalize_path(path) do
    path
    |> Path.expand()
    |> String.trim_trailing("/")
  end

  defp path_label(path) when is_binary(path) and path != "", do: Path.basename(path)
  defp path_label(_path), do: "unassigned"

  defp get(value, []), do: value

  defp get(value, [key | rest]) when is_map(value) do
    value
    |> field(key)
    |> get(rest)
  end

  defp get(_value, _path), do: nil

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp first_present(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
