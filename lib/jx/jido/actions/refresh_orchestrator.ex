defmodule JX.Jido.Actions.RefreshOrchestrator do
  @moduledoc """
  Refresh compact orchestrator state from the live work board and summary.
  """

  use Jido.Action,
    name: "jx_refresh_orchestrator",
    description: "Refresh compact orchestration state from observed sessions",
    category: "jx",
    tags: ["orchestrator", "sessions", "safe"],
    schema: JX.Jido.Actions.WorkspaceAction.opts_schema()

  alias JX.Workspace

  @impl true
  def run(%{opts: opts}, _context) do
    with {:ok, board} <- Workspace.work_board(opts),
         {:ok, dossiers} <- Workspace.session_dossiers(Keyword.put(opts, :observe, false)),
         {:ok, summary} <- Workspace.session_summary(Keyword.put(opts, :observe, false)),
         {:ok, inbox} <- Workspace.orchestrator_inbox(Keyword.put(opts, :observe, false)) do
      planning = planning_summary(inbox)

      {:ok,
       %{
         status: :observed,
         last_board_total: board.total,
         managed_total: count_control(board.items, "managed"),
         directable_total: Enum.count(board.items, & &1.can_direct),
         repo_blocker_total: Enum.count(dossiers.dossiers, &repo_blocker?/1),
         attention_total: summary.observations.attention_total,
         planned_decision_total: planning.decisions,
         manual_decision_total: planning.manual,
         gated_decision_total: planning.gated,
         top_priority: planning.top_priority,
         autonomous_next: planning.autonomous_next,
         operator_needed_total: length(planning.operator_needed_for),
         focus_refs: planning.focus_refs,
         recovery_status: get_in(inbox, [:sections, :recovery, :status]) || "",
         recovery_total: get_in(inbox, [:sections, :recovery, :recommendations_total]) || 0,
         last_error: ""
       }}
    else
      {:error, reason} ->
        {:ok,
         %{
           status: :failed,
           last_error: inspect(reason)
         }}
    end
  end

  defp count_control(items, mode) do
    Enum.count(items, &(Map.get(&1, :control_mode) == mode))
  end

  defp planning_summary(inbox) do
    sections = Map.get(inbox, :sections, %{})
    needs_judgment = Map.get(sections, :needs_judgment, [])
    delegation_reviews = Map.get(sections, :delegation_reviews, [])
    suggestions = Map.get(sections, :suggestions, [])
    recovery = get_in(sections, [:recovery, :recommendations]) || []

    manual =
      length(needs_judgment) + length(delegation_reviews) + Enum.count(recovery, &manual?/1)

    gated = Enum.count(suggestions, &(Map.get(&1, :safety) == "gated"))
    focus_refs = focus_refs(needs_judgment ++ delegation_reviews ++ suggestions ++ recovery)

    %{
      decisions: manual + gated + length(suggestions),
      manual: manual,
      gated: gated,
      focus_refs: focus_refs,
      operator_needed_for: operator_needed_for(manual, recovery),
      top_priority: top_priority(needs_judgment, delegation_reviews, suggestions, recovery),
      autonomous_next: autonomous_next(suggestions, recovery)
    }
  end

  defp manual?(item), do: Map.get(item, :safety) == "manual"

  defp focus_refs(items) do
    items
    |> Enum.map(&(Map.get(&1, :ref, "") || ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp operator_needed_for(manual, recovery) do
    []
    |> maybe_need(manual > 0, "manual planning decision")
    |> maybe_need(recovery != [], "recovery review")
    |> Enum.reverse()
  end

  defp top_priority([item | _rest], _reviews, _suggestions, _recovery) do
    "review #{Map.get(item, :ref, "")}: #{Map.get(item, :next_step, "")}"
  end

  defp top_priority([], [review | _rest], _suggestions, _recovery) do
    "review delegation #{Map.get(review, :delegation_id, "")}"
  end

  defp top_priority([], [], [suggestion | _rest], _recovery) do
    "planner suggestion #{Map.get(suggestion, :ref, "")}: #{Map.get(suggestion, :reason, "")}"
  end

  defp top_priority([], [], [], [recovery | _rest]) do
    "recovery #{Map.get(recovery, :action, "")}: #{Map.get(recovery, :reason, "")}"
  end

  defp top_priority([], [], [], []), do: "no planner decision queued"

  defp autonomous_next([_suggestion | _rest], _recovery), do: "review planner suggestions"
  defp autonomous_next([], [_recovery | _rest]), do: "review recovery recommendations"
  defp autonomous_next([], []), do: "continue monitoring workspace state"

  defp maybe_need(needs, true, item), do: [item | needs]
  defp maybe_need(needs, false, _item), do: needs

  defp repo_blocker?(%{repo: %{blockers: blockers}}), do: blockers != []
  defp repo_blocker?(_dossier), do: false
end
