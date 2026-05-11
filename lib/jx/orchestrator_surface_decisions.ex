defmodule JX.OrchestratorSurfaceDecisions do
  @moduledoc """
  Promotes non-session orchestration surfaces into durable decisions.

  These decisions make call handoffs, CI watch transitions, and delegation
  reviews visible in the same queue as session prompts without auto-mutating
  those external workflows.
  """

  def build(scan, events, _opts \\ []) do
    events_by_ref = events_by_ref(events)

    []
    |> add_call_handoffs(Map.get(scan, :call_handoffs, []), events_by_ref)
    |> add_delegation_reviews(Map.get(scan, :delegation_reviews, []), events_by_ref)
    |> add_ci_watch_updates(Map.get(scan, :ci_watch_updates, []), events_by_ref)
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.id)
  end

  defp add_call_handoffs(decisions, handoffs, events_by_ref) do
    Enum.reduce(handoffs, decisions, fn handoff, acc ->
      ref = field(handoff, :ref)
      title = first_present([field(handoff, :title), field(handoff, :summary)])

      [
        %{
          id: decision_id("call-handoff", field(handoff, :handoff_id), ref, title),
          action: "review-call-handoff",
          source: "call-handoff",
          recommendation_id: field(handoff, :handoff_id),
          safety: "manual",
          status: "planned",
          ref: ref,
          target: field(handoff, :handoff_id),
          reason: first_present([title, "open call handoff needs disposition"]),
          event_ids: event_ids(events_by_ref, ref)
        }
        | acc
      ]
    end)
  end

  defp add_delegation_reviews(decisions, reviews, events_by_ref) do
    Enum.reduce(reviews, decisions, fn review, acc ->
      ref = field(review, :ref)
      delegation_id = field(review, :delegation_id)

      [
        %{
          id: decision_id("delegation-review", delegation_id, ref, field(review, :title)),
          action: "decide-delegation-review",
          source: "delegation",
          recommendation_id: delegation_id,
          safety: "manual",
          status: "planned",
          ref: ref,
          target: delegation_id,
          reason:
            first_present([field(review, :worker_summary), "completed delegation needs review"]),
          event_ids: event_ids(events_by_ref, ref)
        }
        | acc
      ]
    end)
  end

  defp add_ci_watch_updates(decisions, updates, events_by_ref) do
    updates
    |> Enum.filter(&field(&1, :changed?, false))
    |> Enum.reduce(decisions, fn update, acc ->
      watch = field(update, :watch, %{})
      ref = field(watch, :ref)
      watch_id = field(watch, :watch_id)

      [
        %{
          id: decision_id("ci-watch", watch_id, ref, field(update, :status)),
          action: "review-ci-watch",
          source: "ci-watch",
          recommendation_id: watch_id,
          safety: "inspect",
          status: "planned",
          ref: ref,
          target: "#{field(watch, :repo)}##{field(watch, :pr_number)}",
          reason: first_present([field(update, :summary), "CI watch status changed"]),
          event_ids: event_ids(events_by_ref, ref)
        }
        | acc
      ]
    end)
  end

  defp events_by_ref(events) do
    events
    |> Enum.group_by(&field(&1, :ref))
    |> Map.delete("")
  end

  defp event_ids(events_by_ref, ref) do
    events_by_ref
    |> Map.get(ref, [])
    |> Enum.map(&field(&1, :id))
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp decision_id(kind, id, ref, reason) do
    [kind, id, ref, reason]
    |> Enum.map(&stringify/1)
    |> Enum.intersperse(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 10)
    |> then(&("orc-" <> &1))
  end

  defp first_present(values) do
    Enum.find_value(values, "", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end)
  end

  defp field(value, key, default \\ "")

  defp field(%{} = map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key), default)
    end
  end

  defp field(_value, _key, default), do: default

  defp stringify(value) when is_binary(value), do: value
  defp stringify(nil), do: ""
  defp stringify(value), do: to_string(value)
end
