defmodule JX.IDs do
  @moduledoc """
  Deterministic names and paths used to make commands idempotent.
  """

  @slug_pattern ~r/[^a-z0-9]+/

  def slug(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(@slug_pattern, "-")
    |> String.trim("-")
    |> empty_to_default()
  end

  def prompt_hash(project_slug, prompt) do
    :crypto.hash(:sha256, [project_slug, <<0>>, String.trim(prompt)])
    |> Base.encode16(case: :lower)
  end

  def task_id(prompt_hash), do: "task-" <> binary_part(prompt_hash, 0, 12)

  def branch(task_id), do: "jx/#{task_id}"

  def session_name(project_slug, task_id, agent_name) do
    "jx_#{session_slug(project_slug)}_#{session_slug(task_id)}_#{session_slug(agent_name)}"
  end

  def task_paths(host, project, task_id) do
    project_root = Path.join([host.workspace_path, "projects", project.slug])
    task_dir = Path.join([project_root, ".jx", "tasks", task_id])

    %{
      worktree_path: Path.join([project_root, "worktrees", task_id]),
      task_dir: task_dir,
      log_path: Path.join([task_dir, "session.log"])
    }
  end

  defp empty_to_default(""), do: "default"
  defp empty_to_default(value), do: value

  defp session_slug(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> empty_to_default()
  end
end
