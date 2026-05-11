defmodule JX.Workspace.PromotionPreflight do
  @moduledoc """
  Dry-run promotion readiness check.

  Promotion preflight delegates eligibility to the project gate. It does not
  update branches, push, merge, or delete anything.
  """

  def run(project_name, source_branch, target_branch, project_gate_fun)
      when is_function(project_gate_fun, 2) do
    with {:ok, project_gate} <-
           project_gate_fun.(project_name,
             base_branch: source_branch,
             promote_branch: target_branch
           ) do
      {:ok, evaluate(project_name, source_branch, target_branch, project_gate)}
    end
  end

  def evaluate(project_name, source_branch, target_branch, %{} = project_gate) do
    eligible = field(project_gate, :eligible, false) == true

    %{
      project: to_string(project_name),
      source_branch: to_string(source_branch),
      target_branch: to_string(target_branch),
      eligible: eligible,
      status: if(eligible, do: "allowed", else: "blocked"),
      project_gate: project_gate,
      reasons: list_field(project_gate, :reasons),
      required_fixes: list_field(project_gate, :required_fixes)
    }
  end

  defp list_field(map, key) do
    case field(map, key, []) do
      values when is_list(values) -> Enum.map(values, &to_string/1)
      value when value in [nil, ""] -> []
      value -> [to_string(value)]
    end
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
