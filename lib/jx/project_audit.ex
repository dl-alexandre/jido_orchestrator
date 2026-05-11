defmodule JX.ProjectAudit do
  @moduledoc """
  Read-only git workspace audit for registered project instances.
  """

  alias JX.SSH
  alias JX.Shell

  def build(project_name, projects) do
    instances = Enum.map(projects, &audit_project/1)

    %{
      generated_at: DateTime.utc_now(),
      project: project_name,
      registered_instances: length(projects),
      summary: summary(instances),
      instances: instances,
      warnings: registry_warnings(project_name, projects)
    }
  end

  defp audit_project(project) do
    base = project_base(project)

    case SSH.adapter(project.host).run(project.host, audit_script(project.repo_path)) do
      {:ok, output} ->
        output
        |> parse_output()
        |> Map.merge(base)

      {:error, reason} ->
        Map.merge(base, %{
          status: "error",
          error: inspect(reason),
          branch: "",
          head: "",
          upstream: "",
          ahead: nil,
          behind: nil,
          dirty: false,
          changes: [],
          status_short: [],
          worktrees: [],
          warnings: ["audit command failed"]
        })
    end
  end

  defp project_base(project) do
    host = project.host

    %{
      project: project.name,
      host: host.name,
      transport: host.transport,
      ssh_target: host.ssh_target || "",
      workspace_path: host.workspace_path,
      repo_path: project.repo_path
    }
  end

  defp audit_script(repo_path) do
    repo = Shell.quote(repo_path)

    """
    printf 'jx-project-audit\t1\n'
    repo=#{repo}
    printf 'repo_path\t%s\n' "$repo"

    if [ ! -e "$repo" ]; then
      printf 'status\terror\n'
      printf 'error\trepo path missing\n'
      exit 0
    fi

    if [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; then
      printf 'status\terror\n'
      printf 'error\tnot a git repository\n'
      exit 0
    fi

    if ! cd "$repo"; then
      printf 'status\terror\n'
      printf 'error\tcould not cd into repo path\n'
      exit 0
    fi

    printf 'status\tok\n'
    printf 'branch\t%s\n' "$(git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    printf 'head\t%s\n' "$(git rev-parse --verify HEAD 2>/dev/null || true)"
    printf 'upstream\t%s\n' "$(git rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null || true)"
    printf 'ahead_behind\t%s\n' "$(git rev-list --left-right --count @{upstream}...HEAD 2>/dev/null || true)"
    printf 'status_short_start\n'
    git status --short --branch 2>&1 || true
    printf 'status_short_end\n'
    printf 'worktree_start\n'
    git worktree list --porcelain 2>/dev/null || true
    printf 'worktree_end\n'
    """
  end

  defp parse_output(output) do
    lines = String.split(output, "\n", trim: false)
    fields = parse_fields(lines)
    status_short = section(lines, "status_short_start", "status_short_end")
    changes = Enum.reject(status_short, &status_branch_line?/1)
    {behind, ahead} = parse_ahead_behind(Map.get(fields, "ahead_behind", ""))
    status = Map.get(fields, "status", "error")
    upstream = Map.get(fields, "upstream", "")

    %{
      status: status,
      error: Map.get(fields, "error", ""),
      branch: first_present([Map.get(fields, "branch"), status_branch(status_short)]),
      head: Map.get(fields, "head", ""),
      upstream: upstream,
      ahead: ahead,
      behind: behind,
      dirty: changes != [],
      changes: changes,
      status_short: status_short,
      worktrees: parse_worktrees(section(lines, "worktree_start", "worktree_end")),
      warnings: audit_warnings(status, upstream, changes)
    }
  end

  defp parse_fields(lines) do
    lines
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t", parts: 2) do
        [key, value] when key != "" -> [{key, value}]
        _other -> []
      end
    end)
    |> Map.new()
  end

  defp section(lines, start_marker, end_marker) do
    lines
    |> Enum.drop_while(&(&1 != start_marker))
    |> case do
      [] -> []
      [_start | rest] -> Enum.take_while(rest, &(&1 != end_marker))
    end
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_ahead_behind(""), do: {nil, nil}

  defp parse_ahead_behind(value) do
    case String.split(value, ~r/\s+/, trim: true) do
      [behind, ahead] -> {parse_int(behind), parse_int(ahead)}
      _other -> {nil, nil}
    end
  end

  defp status_branch_line?(line), do: String.starts_with?(String.trim_leading(line), "## ")

  defp status_branch(lines) do
    lines
    |> Enum.find(&status_branch_line?/1)
    |> case do
      nil ->
        ""

      line ->
        line
        |> String.trim_leading()
        |> String.replace_prefix("## ", "")
        |> String.split("...", parts: 2)
        |> hd()
        |> String.split(" ", parts: 2)
        |> hd()
    end
  end

  defp parse_worktrees(lines) do
    lines
    |> Enum.reduce({[], %{}}, fn line, {worktrees, current} ->
      case String.split(line, " ", parts: 2) do
        ["worktree", path] when map_size(current) > 0 ->
          {[normalize_worktree(current) | worktrees], %{"worktree" => path}}

        ["worktree", path] ->
          {worktrees, %{"worktree" => path}}

        [key, value] ->
          {worktrees, Map.put(current, key, value)}

        _other ->
          {worktrees, current}
      end
    end)
    |> then(fn
      {worktrees, current} when map_size(current) > 0 ->
        [normalize_worktree(current) | worktrees]

      {worktrees, _current} ->
        worktrees
    end)
    |> Enum.reverse()
  end

  defp normalize_worktree(worktree) do
    %{
      path: Map.get(worktree, "worktree", ""),
      head: Map.get(worktree, "HEAD", ""),
      branch: Map.get(worktree, "branch", "") |> String.replace_prefix("refs/heads/", "")
    }
  end

  defp audit_warnings(status, upstream, changes) do
    []
    |> maybe_add(status != "ok", "workspace audit failed")
    |> maybe_add(status == "ok" and upstream == "", "branch has no upstream")
    |> maybe_add(changes != [], "working tree has local changes")
  end

  defp registry_warnings(_project_name, [_project | _rest]), do: []
  defp registry_warnings(project_name, []), do: ["project #{project_name} is not registered"]

  defp summary(instances) do
    %{
      total: length(instances),
      ok: Enum.count(instances, &(&1.status == "ok")),
      errors: Enum.count(instances, &(&1.status != "ok")),
      dirty: Enum.count(instances, & &1.dirty),
      clean: Enum.count(instances, &(&1.status == "ok" and !&1.dirty)),
      without_upstream: Enum.count(instances, &(&1.status == "ok" and &1.upstream == ""))
    }
  end

  defp maybe_add(values, true, value), do: values ++ [value]
  defp maybe_add(values, false, _value), do: values

  defp parse_int(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp first_present(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end) || ""
  end
end
