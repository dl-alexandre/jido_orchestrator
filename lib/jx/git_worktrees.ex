defmodule JX.GitWorktrees do
  @moduledoc """
  Builds remote git worktree setup scripts.
  """

  alias JX.Shell

  def ensure_worktree_script(project, task, task_json) do
    repo = Shell.quote(project.repo_path)
    worktree = Shell.quote(task.worktree_path)
    task_dir = Shell.quote(task.task_dir)
    branch = Shell.quote(task.branch)
    prompt = Shell.quote(task.prompt)
    goal_write = goal_write_script(task)
    task_json = Shell.quote(task_json)

    """
    set -eu
    repo=#{repo}
    worktree=#{worktree}
    task_dir=#{task_dir}
    branch=#{branch}

    if [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; then
      echo "repo path is not a git checkout: $repo" >&2
      exit 1
    fi

    mkdir -p "$(dirname "$worktree")" "$task_dir/artifacts"
    printf %s #{prompt} > "$task_dir/prompt.md"
    #{goal_write}
    printf %s #{task_json} > "$task_dir/task.json"
    touch #{Shell.quote(task.log_path)}

    if [ ! -d "$worktree/.git" ] && [ ! -f "$worktree/.git" ]; then
      if [ -e "$worktree" ] && [ -n "$(find "$worktree" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]; then
        echo "worktree path exists and is not empty: $worktree" >&2
        exit 1
      fi
      git -C "$repo" worktree add -B "$branch" "$worktree" HEAD
    fi
    """
  end

  defp goal_write_script(task) do
    case Map.get(task, :goal_objective) || Map.get(task, "goal_objective") do
      value when is_binary(value) and value != "" ->
        "printf %s #{Shell.quote(value)} > \"$task_dir/goal.md\""

      _other ->
        ""
    end
  end
end
