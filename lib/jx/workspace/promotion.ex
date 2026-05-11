defmodule JX.Workspace.Promotion do
  @moduledoc """
  Conservative promotion execution.

  Promotion execution is intentionally a thin wrapper around a green promotion
  preflight. Blocked preflight results never call the mutating runner.
  """

  alias JX.Shell

  def run(project_name, source_branch, target_branch, preflight_fun, promotion_fun)
      when is_function(preflight_fun, 3) and is_function(promotion_fun, 1) do
    with {:ok, preflight} <- preflight_fun.(project_name, source_branch, target_branch) do
      cond do
        not eligible?(preflight) ->
          {:ok, report(project_name, source_branch, target_branch, "blocked", preflight, [], [])}

        hosts(preflight) |> length() != 1 ->
          {:ok,
           report(
             project_name,
             source_branch,
             target_branch,
             "failed",
             preflight,
             [],
             host_selection_errors(preflight)
           )}

        true ->
          run_promotion(project_name, source_branch, target_branch, preflight, promotion_fun)
      end
    end
  end

  def promotion_script(repo_path, source_branch, target_branch) do
    repo = Shell.quote(repo_path)
    source = Shell.quote(source_branch)
    target = Shell.quote(target_branch)

    """
    printf 'jx-promotion-run\t1\n'
    repo=#{repo}
    source=#{source}
    target=#{target}
    printf 'repo_path\t%s\n' "$repo"
    printf 'source_branch\t%s\n' "$source"
    printf 'target_branch\t%s\n' "$target"

    fail() {
      printf 'status\tfailed\n'
      printf 'error\t%s\n' "$1"
      exit 0
    }

    if [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; then
      fail "not a git repository"
    fi

    if ! cd "$repo"; then
      fail "could not cd into repo path"
    fi

    remote="$(git remote 2>/dev/null | head -n 1 || true)"
    if [ -z "$remote" ]; then
      fail "no git remote configured"
    fi

    source_ref="refs/remotes/$remote/$source"
    target_ref="refs/remotes/$remote/$target"

    printf 'action\tfetch %s %s\n' "$source" "$target"
    fetch_output="$(git fetch "$remote" "refs/heads/$source:$source_ref" "refs/heads/$target:$target_ref" 2>&1)" ||
      fail "fetch failed: $fetch_output"

    printf 'action\tcheckout %s\n' "$target"
    checkout_output="$(git checkout "$target" 2>&1)" ||
      fail "checkout failed: $checkout_output"

    printf 'action\tmerge --ff-only %s\n' "$source_ref"
    merge_output="$(git merge --ff-only "$source_ref" 2>&1)" ||
      fail "merge failed: $merge_output"

    printf 'action\tpush %s\n' "$target"
    push_output="$(git push "$remote" "$target" 2>&1)" ||
      fail "push failed: $push_output"

    printf 'status\tpromoted\n'
    """
  end

  def parse_output(output) do
    lines = String.split(to_string(output), "\n", trim: true)
    actions = values(lines, "action")
    errors = values(lines, "error")

    case last_value(lines, "status") do
      "promoted" -> {:ok, actions}
      "failed" -> {:error, actions, errors}
      status when status in [nil, ""] -> {:error, actions, ["promotion did not report status"]}
      status -> {:error, actions, ["promotion reported unexpected status #{status}"]}
    end
  end

  defp run_promotion(project_name, source_branch, target_branch, preflight, promotion_fun) do
    case promotion_fun.(preflight) do
      {:ok, actions} ->
        {:ok,
         report(project_name, source_branch, target_branch, "promoted", preflight, actions, [])}

      {:error, actions, errors} ->
        {:ok,
         report(project_name, source_branch, target_branch, "failed", preflight, actions, errors)}
    end
  end

  defp report(project_name, source_branch, target_branch, status, preflight, actions, errors) do
    %{
      project: to_string(project_name),
      source_branch: to_string(source_branch),
      target_branch: to_string(target_branch),
      status: status,
      preflight: preflight,
      actions: Enum.map(actions, &to_string/1),
      errors: Enum.map(errors, &to_string/1)
    }
  end

  defp eligible?(preflight), do: field(preflight, :eligible, false) == true

  defp host_selection_errors(preflight) do
    case hosts(preflight) do
      [] ->
        ["promotion requires exactly one eligible host"]

      hosts ->
        ["ambiguous promotion hosts: #{hosts |> Enum.map(&host_name/1) |> Enum.join(", ")}"]
    end
  end

  defp hosts(preflight) do
    preflight
    |> field(:project_gate, %{})
    |> field(:hosts, [])
    |> case do
      hosts when is_list(hosts) -> hosts
      _other -> []
    end
  end

  defp host_name(host), do: field(host, :host, "")

  defp values(lines, key) do
    lines
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t", parts: 2) do
        [^key, value] -> [String.trim(value)]
        _other -> []
      end
    end)
  end

  defp last_value(lines, key) do
    lines
    |> values(key)
    |> List.last()
  end

  defp field(map, key, default) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, to_string(key)) -> Map.get(map, to_string(key))
      true -> default
    end
  end

  defp field(_value, _key, default), do: default
end
