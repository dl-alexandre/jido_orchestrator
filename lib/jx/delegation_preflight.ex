defmodule JX.DelegationPreflight do
  @moduledoc """
  Lints delegation packets and detects write ownership conflicts.
  """

  alias JX.Delegations.Delegation

  @open_statuses ~w(queued running blocked)
  @write_agent_kinds ~w(worker codex claude opencode)
  @risky_patterns [
    ~r/\bgit\s+push\b|\bpush\b.*\b(branch|PR|pull request)\b/i,
    ~r/\bforce[- ]?push\b/i,
    ~r/\brebase\b/i,
    ~r/\bmerge\b.*\b(main|master|develop)\b/i,
    ~r/\brelease\b/i,
    ~r/\bdeploy\b/i,
    ~r/\bcredential|secret|token|api key\b/i,
    ~r/\brm\s+-rf\b/i,
    ~r/\bdrop\b.*\bdatabase\b/i
  ]

  def lint(%Delegation{} = delegation, open_delegations \\ []) do
    delegation
    |> delegation_attrs()
    |> lint(open_delegations, delegation.delegation_id)
  end

  def lint(attrs, open_delegations, self_id) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)
    write_paths = json_list(attrs, :write_paths)
    forbidden_paths = json_list(attrs, :forbidden_paths)
    warnings = packet_warnings(attrs, write_paths, forbidden_paths)
    conflicts = conflicts(attrs, write_paths, open_delegations, self_id)
    conflict_warnings = Enum.map(conflicts, &conflict_warning/1)
    all_warnings = Enum.uniq(warnings ++ conflict_warnings)

    %{
      status: status(all_warnings, conflicts),
      warnings: all_warnings,
      conflicts: conflicts,
      write_paths: write_paths,
      forbidden_paths: forbidden_paths,
      missing: missing_fields(attrs, write_paths),
      gated: risky_text?(attrs)
    }
  end

  def start_gate(%Delegation{} = delegation, open_delegations) do
    report = lint(delegation, open_delegations)

    if report.conflicts == [] do
      {:ok, report}
    else
      {:error, {:delegation_conflict, report}}
    end
  end

  def open_status?(status), do: status in @open_statuses

  def lint_warnings(attrs, open_delegations \\ [], self_id \\ nil) do
    attrs
    |> lint(open_delegations, self_id)
    |> Map.fetch!(:warnings)
  end

  defp packet_warnings(attrs, write_paths, forbidden_paths) do
    []
    |> warn_if(blank?(field(attrs, :project)), "packet missing project")
    |> warn_if(blank?(field(attrs, :ref)), "packet missing session/ref")
    |> warn_if(empty_json_list?(attrs, :context), "packet missing context")
    |> warn_if(empty_json_list?(attrs, :constraints), "packet missing constraints")
    |> warn_if(empty_json_list?(attrs, :acceptance), "packet missing acceptance criteria")
    |> warn_if(empty_json_list?(attrs, :verification), "packet missing verification commands")
    |> warn_if(
      write_agent?(field(attrs, :agent_kind)) and write_paths == [],
      "write-capable delegation missing --write ownership paths"
    )
    |> warn_if(
      write_agent?(field(attrs, :agent_kind)) and forbidden_paths == [] and
        empty_json_list?(attrs, :constraints),
      "write-capable delegation should name forbidden paths or constraints"
    )
    |> warn_if(
      risky_text?(attrs),
      "packet mentions gated operations; foreground review required before external/destructive action"
    )
  end

  defp missing_fields(attrs, write_paths) do
    [
      {:project, blank?(field(attrs, :project))},
      {:ref, blank?(field(attrs, :ref))},
      {:context, empty_json_list?(attrs, :context)},
      {:constraints, empty_json_list?(attrs, :constraints)},
      {:acceptance, empty_json_list?(attrs, :acceptance)},
      {:verification, empty_json_list?(attrs, :verification)},
      {:write_paths, write_agent?(field(attrs, :agent_kind)) and write_paths == []}
    ]
    |> Enum.filter(fn {_field, missing?} -> missing? end)
    |> Enum.map(fn {field, _missing?} -> field end)
  end

  defp conflicts(attrs, write_paths, open_delegations, self_id) do
    open_delegations
    |> Enum.filter(&conflict_candidate?(&1, attrs, self_id))
    |> Enum.flat_map(&path_conflicts(&1, write_paths))
  end

  defp conflict_candidate?(%Delegation{} = other, attrs, self_id) do
    other.delegation_id != self_id and open_status?(other.status) and same_project?(other, attrs)
  end

  defp conflict_candidate?(_other, _attrs, _self_id), do: false

  defp same_project?(%Delegation{project: project}, attrs) do
    packet_project = field(attrs, :project)
    blank?(project) or blank?(packet_project) or project == packet_project
  end

  defp path_conflicts(%Delegation{} = other, write_paths) do
    other_write_paths = json_list(other.write_paths)

    for path <- write_paths,
        other_path <- other_write_paths,
        overlapping_path?(path, other_path) do
      %{
        delegation_id: other.delegation_id,
        status: other.status,
        owner: other.owner,
        project: other.project,
        title: other.title,
        path: path,
        conflicting_path: other_path
      }
    end
  end

  defp conflict_warning(conflict) do
    "write path #{conflict.path} overlaps #{conflict.conflicting_path} in #{conflict.delegation_id}"
  end

  defp overlapping_path?(left, right) do
    left = normalize_path(left)
    right = normalize_path(right)

    cond do
      left == "" or right == "" -> false
      left == right -> true
      String.starts_with?(left, right <> "/") -> true
      String.starts_with?(right, left <> "/") -> true
      true -> false
    end
  end

  defp normalize_path(path) do
    path
    |> to_string()
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.split("/", trim: true)
    |> normalize_path_segments([])
    |> Enum.join("/")
  end

  defp normalize_path_segments([], acc), do: Enum.reverse(acc)
  defp normalize_path_segments(["." | rest], acc), do: normalize_path_segments(rest, acc)

  defp normalize_path_segments([".." | rest], [".." | _] = acc),
    do: normalize_path_segments(rest, [".." | acc])

  defp normalize_path_segments([".." | rest], [_segment | acc]),
    do: normalize_path_segments(rest, acc)

  defp normalize_path_segments([".." | rest], []), do: normalize_path_segments(rest, [".."])

  defp normalize_path_segments([segment | rest], acc),
    do: normalize_path_segments(rest, [segment | acc])

  defp status(_warnings, [_conflict | _rest]), do: "blocked"
  defp status([], []), do: "ready"
  defp status(_warnings, []), do: "warning"

  defp write_agent?(agent_kind), do: (agent_kind || "worker") in @write_agent_kinds

  defp risky_text?(attrs) do
    text =
      [
        field(attrs, :title),
        field(attrs, :brief),
        json_list(attrs, :context),
        json_list(attrs, :constraints),
        json_list(attrs, :acceptance)
      ]
      |> List.flatten()
      |> Enum.join("\n")

    Enum.any?(@risky_patterns, &Regex.match?(&1, text))
  end

  defp delegation_attrs(%Delegation{} = delegation) do
    %{
      title: delegation.title,
      brief: delegation.brief,
      project: delegation.project,
      ref: delegation.ref,
      owner: delegation.owner,
      agent_kind: delegation.agent_kind,
      context: delegation.context,
      constraints: delegation.constraints,
      acceptance: delegation.acceptance,
      verification: delegation.verification,
      write_paths: delegation.write_paths,
      forbidden_paths: delegation.forbidden_paths
    }
  end

  defp warn_if(warnings, true, warning), do: warnings ++ [warning]
  defp warn_if(warnings, false, _warning), do: warnings

  defp empty_json_list?(attrs, key), do: json_list(attrs, key) == []

  defp json_list(attrs, key), do: attrs |> field(key) |> json_list()

  defp json_list(nil), do: []

  defp json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> normalize_list(list)
      _other -> normalize_list([value])
    end
  end

  defp json_list(value) when is_list(value), do: normalize_list(value)
  defp json_list(_value), do: []

  defp normalize_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp field(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
