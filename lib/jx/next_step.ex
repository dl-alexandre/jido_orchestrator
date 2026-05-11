defmodule JX.NextStep do
  @moduledoc """
  Builds a single recommended next operator action from a call brief.
  """

  alias JX.UsageModes

  def build(brief) do
    agenda_item =
      brief
      |> field(:agenda, [])
      |> List.wrap()
      |> List.first()

    orchestrator = field(brief, :orchestrator, %{}) || %{}
    mode_id = mode_id(agenda_item, orchestrator)
    mode = UsageModes.fetch(mode_id) || %{}

    %{
      generated_at: field(brief, :generated_at),
      next: next_text(brief, orchestrator),
      mode: mode_id,
      mode_title: field(mode, :title, mode_id),
      command: command(agenda_item, orchestrator),
      reason: reason(agenda_item, orchestrator),
      agenda_item: agenda_item,
      orchestrator: orchestrator_summary(orchestrator),
      focus_refs: field(orchestrator, :focus_refs, [])
    }
  end

  defp next_text(brief, orchestrator) do
    first_present([
      field(brief, :next),
      field(orchestrator, :top_priority),
      field(orchestrator, :autonomous_next),
      "Keep background orchestration running and wait for the next watch or session change."
    ])
  end

  defp mode_id(%{kind: kind}, _orchestrator)
       when kind in ["delegation", "delegation_review"],
       do: "delegation"

  defp mode_id(%{kind: "handoff"}, _orchestrator), do: "meet"
  defp mode_id(%{kind: "ci_watch"}, _orchestrator), do: "watch"

  defp mode_id(%{kind: kind}, _orchestrator) when kind in ["judgment", "ready"],
    do: "session-control"

  defp mode_id(%{kind: "observe"}, _orchestrator), do: "tui"
  defp mode_id(%{kind: "notification"}, _orchestrator), do: "tui"

  defp mode_id(_agenda_item, orchestrator) do
    cond do
      field(orchestrator, :operator_needed_for, []) != [] -> "tui"
      field(orchestrator, :status) == "running" -> "daemon"
      true -> "dry-run"
    end
  end

  defp command(%{kind: kind, id: id}, _orchestrator)
       when kind in ["delegation", "delegation_review"] and id not in [nil, ""] do
    "jx delegate review #{id} --json"
  end

  defp command(%{kind: "handoff", id: id}, _orchestrator) when id not in [nil, ""] do
    "jx call handoff apply #{id} --json"
  end

  defp command(%{kind: "ci_watch", id: id}, _orchestrator) when id not in [nil, ""] do
    "jx ci review #{id} --json"
  end

  defp command(%{kind: kind, ref: ref}, _orchestrator)
       when kind in ["judgment", "ready"] and ref not in [nil, ""] do
    "jx orchestrator review #{ref}"
  end

  defp command(%{kind: "observe", ref: ref}, _orchestrator) when ref not in [nil, ""] do
    "jx session capture #{ref} -n 80"
  end

  defp command(%{kind: "notification"}, _orchestrator) do
    "jx notifications ls --status unread"
  end

  defp command(_agenda_item, orchestrator) do
    cond do
      field(orchestrator, :operator_needed_for, []) != [] -> "jx call brief --observe"
      field(orchestrator, :status) == "running" -> "jx orchestrator status"
      true -> "jx orchestrate step --auto-plan --json"
    end
  end

  defp reason(%{kind: kind, label: label}, _orchestrator) when label not in [nil, ""] do
    "#{kind}: #{label}"
  end

  defp reason(%{kind: kind}, _orchestrator), do: "#{kind} agenda item"

  defp reason(_agenda_item, orchestrator) do
    first_present([
      field(orchestrator, :top_priority),
      field(orchestrator, :autonomous_next),
      "no urgent agenda item"
    ])
  end

  defp orchestrator_summary(orchestrator) do
    %{
      status: field(orchestrator, :status, "unknown"),
      consumer: field(orchestrator, :consumer, ""),
      mode: field(orchestrator, :mode, ""),
      top_priority: field(orchestrator, :top_priority, ""),
      autonomous_next: field(orchestrator, :autonomous_next, ""),
      operator_needed_for: field(orchestrator, :operator_needed_for, []),
      focus_refs: field(orchestrator, :focus_refs, [])
    }
  end

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp field(_value, _key, default), do: default

  defp first_present(values) do
    values
    |> Enum.find("", &present?/1)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: value not in [nil, "", []]
end
