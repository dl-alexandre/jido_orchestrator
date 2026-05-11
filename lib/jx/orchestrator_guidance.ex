defmodule JX.OrchestratorGuidance do
  @moduledoc """
  Builds compact foreground guidance from an orchestration report.
  """

  alias JX.BlockedReasons

  def build(report, _opts \\ []) do
    profiles = get_in(report, [:scan, :profiles]) || []
    queues = get_in(report, [:scan, :queues]) || []
    decisions = Map.get(report, :decisions, [])
    errors = Map.get(report, :errors, [])
    notifications = get_in(report, [:scan, :notifications]) || []

    counts = counts(profiles, queues, decisions, report, notifications)

    %{
      top_priority: top_priority(profiles, queues, decisions, errors, counts),
      autonomous_next: autonomous_next(report, counts),
      operator_needed_for:
        operator_needed_for(profiles, decisions, errors, notifications, counts),
      counts: counts,
      focus_refs: focus_refs(profiles, queues, decisions, report)
    }
  end

  defp counts(profiles, queues, decisions, report, notifications) do
    profile_blocked = Enum.count(profiles, &blocked?/1)
    profile_ready = Enum.count(profiles, &ready?/1)
    profile_awaiting = Enum.count(profiles, &awaiting?/1)

    %{
      blocked: max(profile_blocked, queue_total(queues, "blocked-profile")),
      blocked_by_reason: BlockedReasons.urgent_counts(profiles),
      parked: Enum.count(profiles, &BlockedReasons.parked?/1),
      done: Enum.count(profiles, &BlockedReasons.done?/1),
      ready: profile_ready,
      directable: queue_total(queues, "send-session"),
      awaiting: max(profile_awaiting, queue_total(queues, "observe")),
      stale: Enum.count(profiles, &stale?/1),
      operator_needed_sessions: Enum.count(profiles, &coordination_operator_needed?/1),
      autonomous_sessions: Enum.count(profiles, &coordination_agent_can_continue?/1),
      adopt: queue_total(queues, "adopt"),
      inspect: queue_total(queues, "inspect"),
      manual_decisions: Enum.count(decisions, &(Map.get(&1, :safety) == "manual")),
      gated_decisions: Enum.count(decisions, &(Map.get(&1, :safety) == "gated")),
      decisions: length(decisions),
      executed: report |> get_in([:execution, :executed]) |> List.wrap() |> length(),
      skipped: report |> get_in([:execution, :skipped]) |> List.wrap() |> length(),
      watch_actions: get_in(report, [:scan, :watch_actions_total]) || 0,
      notifications: length(notifications),
      handoffs: get_in(report, [:scan, :call_handoffs_total]) || 0,
      delegations: get_in(report, [:scan, :delegations_total]) || 0,
      delegation_reviews: get_in(report, [:scan, :delegation_reviews_total]) || 0,
      delegation_long_running:
        get_in(report, [:scan, :delegation_timing, :active, :long_running]) || 0,
      stale_delegation_reviews:
        get_in(report, [:scan, :delegation_timing, :pending_reviews, :stale]) || 0,
      delegation_warnings: get_in(report, [:scan, :delegation_preflight, :warnings_total]) || 0,
      delegation_conflicts: get_in(report, [:scan, :delegation_preflight, :conflicts_total]) || 0,
      delegation_blocked: get_in(report, [:scan, :delegation_preflight, :blocked]) || 0,
      unread_events: get_in(report, [:inbox, :unread_total]) || 0
    }
  end

  defp top_priority(_profiles, _queues, _decisions, [error | _rest], _counts) do
    "resolve orchestrator error: #{inspect(error)}"
    |> truncate(180)
  end

  defp top_priority(profiles, queues, decisions, _errors, counts) do
    decisions
    |> Enum.find(&(Map.get(&1, :safety) == "manual"))
    |> case do
      nil -> nil
      decision -> "operator review #{decision.ref}: #{decision.reason}"
    end
    |> case do
      nil -> next_priority(profiles, queues, decisions, counts)
      priority -> truncate(priority, 180)
    end
  end

  defp next_priority(profiles, queues, decisions, counts) do
    cond do
      decision = Enum.find(decisions, &(Map.get(&1, :safety) == "gated")) ->
        "gated action #{decision.action} for #{decision.ref}: #{decision.reason}"

      Map.get(counts, :handoffs) > 0 ->
        "call handoff queue: #{Map.get(counts, :handoffs)} open handoff(s)"

      Map.get(counts, :delegation_conflicts) > 0 ->
        "delegation write conflict: #{Map.get(counts, :delegation_blocked)} blocked packet(s)"

      Map.get(counts, :delegation_reviews) > 0 ->
        "delegation review queue: #{Map.get(counts, :delegation_reviews)} completed packet(s)"

      Map.get(counts, :delegation_long_running) > 0 ->
        "delegation runtime watch: #{Map.get(counts, :delegation_long_running)} long-running packet(s)"

      Map.get(counts, :delegations) > 0 ->
        "delegation queue: #{Map.get(counts, :delegations)} active packet(s)"

      profile = Enum.find(profiles, &ready?/1) ->
        "ready #{profile.ref}: #{profile.next_step}"

      queue_total(queues, "observe") > 0 ->
        "observe queue: #{queue_total(queues, "observe")} session(s) awaiting observation"

      profile = Enum.find(profiles, &awaiting?/1) ->
        "awaiting observation #{profile.ref}"

      queue_total(queues, "blocked-profile") > 0 ->
        "blocked-profile queue: #{queue_total(queues, "blocked-profile")} session(s) need strategy"

      profile = Enum.find(profiles, &blocked?/1) ->
        "blocked #{profile.ref}: #{profile.next_step}"

      queue_total(queues, "send-session") > 0 ->
        "send-session queue: #{queue_total(queues, "send-session")} directable session(s) need prompt review"

      true ->
        "keep daemon running; no operator decision queued"
    end
    |> truncate(180)
  end

  defp autonomous_next(report, counts) do
    cond do
      Map.get(counts, :executed) > 0 ->
        "observe executed actions on the next loop"

      Map.get(counts, :watch_actions) > 0 ->
        "continue from watch-updated profile state"

      Map.get(counts, :handoffs) > 0 ->
        "review open call handoffs and convert them into prompts, watches, or closures"

      Map.get(counts, :delegation_conflicts) > 0 ->
        "resolve delegation write conflicts before starting more worker agents"

      Map.get(counts, :delegation_reviews) > 0 ->
        "review completed delegation output and record accept/revise/reject/hold decisions"

      Map.get(counts, :delegation_long_running) > 0 ->
        "inspect long-running delegations before assigning more overlapping work"

      Map.get(counts, :delegations) > 0 ->
        "review active delegation packets and integrate worker results"

      Map.get(counts, :awaiting) > 0 ->
        "observe awaiting sessions and clear sent prompts when responses arrive"

      Map.get(counts, :ready) > 0 and String.contains?(Map.get(report, :mode, ""), "execute") ->
        "send ready managed prompts when freshness and policy allow"

      Map.get(counts, :directable) > 0 ->
        "review directable sessions and chamber prompts only when objective is clear"

      Map.get(counts, :stale) > 0 ->
        "refresh stale session profiles"

      true ->
        "keep scanning sessions, profiles, watches, and notifications"
    end
  end

  defp operator_needed_for(profiles, decisions, errors, notifications, counts) do
    []
    |> maybe_need(errors != [], "orchestrator error")
    |> maybe_need(Enum.any?(decisions, &(Map.get(&1, :safety) == "manual")), "manual decision")
    |> maybe_need(gated_hold?(decisions, counts), "gated action approval")
    |> maybe_need(Map.get(counts, :delegation_conflicts) > 0, "delegation write conflict")
    |> maybe_need(Map.get(counts, :delegation_reviews) > 0, "delegation integration decision")
    |> maybe_need(Map.get(counts, :delegation_long_running) > 0, "long-running delegation")
    |> maybe_need(
      blocked_for_operator?(profiles) or Map.get(counts, :blocked) > 0,
      "blocked session strategy"
    )
    |> maybe_need(Map.get(counts, :operator_needed_sessions) > 0, "session operator decision")
    |> maybe_need(Map.get(counts, :handoffs) > 0, "call handoff")
    |> maybe_need(Map.get(counts, :delegations) > 0, "delegation review")
    |> maybe_need(Enum.any?(notifications, &warning?/1), "warning notification")
    |> Enum.reverse()
  end

  defp focus_refs(profiles, queues, decisions, report) do
    decision_refs =
      decisions
      |> Enum.map(&Map.get(&1, :ref, ""))
      |> Enum.reject(&(&1 == ""))

    queue_refs =
      queues
      |> Enum.flat_map(&(Map.get(&1, :items, []) || []))
      |> Enum.map(&Map.get(&1, :ref, ""))
      |> Enum.reject(&(&1 == ""))

    profile_refs =
      profiles
      |> Enum.filter(&(blocked?(&1) or ready?(&1) or awaiting?(&1)))
      |> Enum.map(&Map.get(&1, :ref, ""))
      |> Enum.reject(&(&1 == ""))

    delegation_review_refs =
      report
      |> get_in([:scan, :delegation_reviews])
      |> List.wrap()
      |> Enum.map(&Map.get(&1, :ref, ""))
      |> Enum.reject(&(&1 == ""))

    (decision_refs ++ delegation_review_refs ++ queue_refs ++ profile_refs)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp queue_total(queues, action) do
    queues
    |> Enum.find(%{}, &(Map.get(&1, :action) == action))
    |> Map.get(:total, 0)
  end

  defp gated_hold?(decisions, counts) do
    Map.get(counts, :gated_decisions) > 0 and
      Enum.any?(decisions, &(Map.get(&1, :status) in ["planned", "skipped"]))
  end

  defp blocked_for_operator?(profiles) do
    Enum.any?(profiles, fn profile ->
      blocked?(profile) and get_in(profile, [:next_prompt, :status]) == "blocked"
    end)
  end

  defp warning?(notification) do
    Map.get(notification, :severity) in ["warning", "critical"]
  end

  defp blocked?(profile), do: BlockedReasons.urgent?(profile)

  defp ready?(profile) do
    get_in(profile, [:comparison, :state]) == "ready-to-send" or
      get_in(profile, [:next_prompt, :status]) == "ready"
  end

  defp awaiting?(profile), do: get_in(profile, [:comparison, :state]) == "awaiting-observation"

  defp stale?(profile) do
    get_in(profile, [:timing, :stale]) == true
  end

  defp coordination_operator_needed?(profile) do
    get_in(profile, [:coordination, :operator_needed]) == true
  end

  defp coordination_agent_can_continue?(profile) do
    get_in(profile, [:coordination, :agent_can_continue]) == true
  end

  defp maybe_need(needs, true, reason), do: [reason | needs]
  defp maybe_need(needs, false, _reason), do: needs

  defp truncate(value, max) when byte_size(value) <= max, do: value
  defp truncate(value, max), do: binary_part(value, 0, max) <> "..."
end
