defmodule JX.OrchestrationActions do
  @moduledoc """
  Durable queue of orchestration intentions and their final outcomes.

  Outcomes are deterministic labels attached when an action reaches a terminal
  execution state. They give planner prompts a feedback surface without
  requiring LLM judgment:

    * `helpful` - the action executed and moved durable state forward
    * `ignored` - the action was skipped before execution
    * `blocked` - the action could not proceed without operator or external input
    * `superseded` - the action was cancelled or no longer matched live work
    * `failed` - the action errored
  """

  import Ecto.Query

  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Repo

  @action_prefix "act-"

  def statuses, do: OrchestrationAction.statuses()
  def outcomes, do: OrchestrationAction.outcomes()

  def record_planned(requested, decisions, opts \\ []) do
    source = Keyword.get(opts, :source, "orchestrate")
    now = DateTime.utc_now()

    decisions
    |> Enum.map(&attrs_from_result(requested, source, &1, "planned", now))
    |> upsert_all()
  end

  def record_results(requested, results, opts \\ []) do
    source = Keyword.get(opts, :source, "orchestrate")
    now = DateTime.utc_now()

    results
    |> Enum.map(&attrs_from_result(requested, source, &1, result_status(&1), now))
    |> upsert_all()
  end

  def record_result(requested, result, opts \\ []) do
    case record_results(requested, [result], opts) do
      %{saved: 1, records: [record], errors: []} -> {:ok, record}
      %{records: [record], errors: []} -> {:ok, record}
      %{errors: [error | _rest]} -> {:error, error}
    end
  end

  def list_actions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    OrchestrationAction
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_outcome(Keyword.get(opts, :outcome))
    |> maybe_filter_source(Keyword.get(opts, :source))
    |> maybe_filter_ref(Keyword.get(opts, :ref))
    |> maybe_filter_action(Keyword.get(opts, :action))
    |> order_by([action], desc: action.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def summary(opts \\ []) do
    actions = list_actions(Keyword.put_new(opts, :limit, 500))

    %{
      total: length(actions),
      by_status: count_by(actions, & &1.status),
      by_outcome: count_by(actions, & &1.outcome),
      by_source: count_by(actions, & &1.source),
      by_action: count_by(actions, & &1.action),
      pending_total: Enum.count(actions, &(&1.status in ["planned", "queued"])),
      error_total: Enum.count(actions, &(&1.status == "error")),
      latest:
        actions
        |> Enum.take(Keyword.get(opts, :latest, 10))
        |> Enum.map(&action_summary/1)
    }
  end

  defp upsert_all(attrs_list) do
    Repo.transaction(fn ->
      Enum.map(attrs_list, fn attrs ->
        action =
          Repo.get_by(OrchestrationAction, queue_key: attrs.queue_key) || %OrchestrationAction{}

        action
        |> OrchestrationAction.changeset(attrs)
        |> Repo.insert_or_update()
        |> case do
          {:ok, action} -> action
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
    |> case do
      {:ok, records} -> %{saved: length(records), records: records, errors: []}
      {:error, reason} -> %{saved: 0, records: [], errors: [inspect(reason)]}
    end
  end

  defp attrs_from_result(requested, source, result, status, now) do
    recommendation_id = Map.get(result, :id) || Map.get(result, :watch_id) || ""
    outcome = result_outcome(status, result)

    %{
      action_id: existing_action_id(requested, source, recommendation_id, result),
      queue_key: queue_key(requested, source, recommendation_id, result),
      requested: requested || "",
      source: source || "",
      recommendation_id: recommendation_id,
      action: Map.get(result, :action, ""),
      safety: Map.get(result, :safety, ""),
      ref: Map.get(result, :ref, ""),
      target: Map.get(result, :target, ""),
      status: status,
      reason: Map.get(result, :reason, ""),
      error: Map.get(result, :error, ""),
      result_summary: result_summary(result),
      outcome: outcome,
      outcome_reason: outcome_reason(outcome, result),
      payload: encode_payload(result),
      scheduled_at: Map.get(result, :scheduled_at) || now,
      executed_at:
        if(status in ["executed", "skipped", "error", "cancelled"], do: now, else: nil),
      completed_at: if(outcome == "", do: nil, else: now)
    }
  end

  defp existing_action_id(requested, source, recommendation_id, result) do
    queue_key = queue_key(requested, source, recommendation_id, result)

    case Repo.get_by(OrchestrationAction, queue_key: queue_key) do
      %OrchestrationAction{action_id: action_id} -> action_id
      nil -> action_id()
    end
  end

  defp queue_key(requested, source, recommendation_id, result) do
    [
      requested || "",
      source || "",
      recommendation_id || "",
      Map.get(result, :action, ""),
      Map.get(result, :ref, ""),
      Map.get(result, :target, "")
    ]
    |> fingerprint("q")
  end

  defp result_status(result), do: Map.get(result, :status, "planned")

  defp result_outcome(_status, %{outcome: outcome}) when outcome in ["", nil], do: ""

  defp result_outcome(_status, %{outcome: outcome}) when is_binary(outcome), do: outcome

  defp result_outcome(status, result) do
    case status do
      "executed" -> executed_outcome(result)
      "skipped" -> skipped_outcome(result)
      "error" -> "failed"
      "cancelled" -> "superseded"
      _other -> ""
    end
  end

  defp executed_outcome(%{action: action})
       when action in ["auto-hold", "hold-profile", "handoff-hold"] do
    "blocked"
  end

  defp executed_outcome(_result), do: "helpful"

  defp skipped_outcome(result) do
    reason = result |> Map.get(:reason, "") |> String.downcase()

    cond do
      String.contains?(reason, ["requires --yes", "requires explicit", "requires manual"]) ->
        "blocked"

      String.contains?(reason, ["not found", "no executable handler", "no longer"]) ->
        "superseded"

      true ->
        "ignored"
    end
  end

  defp outcome_reason("", _result), do: ""

  defp outcome_reason(_outcome, %{outcome_reason: reason}) when is_binary(reason) do
    String.trim(reason)
  end

  defp outcome_reason(outcome, result) do
    first_present([
      Map.get(result, :error),
      Map.get(result, :result_summary),
      Map.get(result, :reason),
      default_outcome_reason(outcome)
    ])
  end

  defp default_outcome_reason("helpful"), do: "action executed"
  defp default_outcome_reason("ignored"), do: "action skipped"
  defp default_outcome_reason("blocked"), do: "action blocked"
  defp default_outcome_reason("superseded"), do: "action superseded"
  defp default_outcome_reason("failed"), do: "action failed"
  defp default_outcome_reason(_outcome), do: ""

  defp first_present(values) do
    values
    |> Enum.find_value("", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      nil ->
        nil

      value ->
        to_string(value)
    end)
  end

  defp result_summary(%{result_summary: summary}), do: summary || ""
  defp result_summary(%{error: error}), do: error || ""
  defp result_summary(%{reason: reason}), do: reason || ""
  defp result_summary(_result), do: ""

  defp encode_payload(result) do
    Jason.encode!(result)
  rescue
    Protocol.UndefinedError -> inspect(result)
    ArgumentError -> inspect(result)
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [action], action.status == ^status)

  defp maybe_filter_outcome(query, nil), do: query

  defp maybe_filter_outcome(query, outcome),
    do: where(query, [action], action.outcome == ^outcome)

  defp maybe_filter_source(query, nil), do: query
  defp maybe_filter_source(query, source), do: where(query, [action], action.source == ^source)

  defp maybe_filter_ref(query, nil), do: query
  defp maybe_filter_ref(query, ref), do: where(query, [action], action.ref == ^ref)

  defp maybe_filter_action(query, nil), do: query
  defp maybe_filter_action(query, action), do: where(query, [record], record.action == ^action)

  defp count_by(items, fun) do
    items
    |> Enum.map(fun)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
  end

  defp action_summary(%OrchestrationAction{} = action) do
    %{
      action_id: action.action_id,
      queue_key: action.queue_key,
      requested: action.requested,
      source: action.source,
      recommendation_id: action.recommendation_id,
      action: action.action,
      safety: action.safety,
      ref: action.ref,
      target: action.target,
      status: action.status,
      reason: action.reason,
      error: action.error,
      result_summary: action.result_summary,
      outcome: action.outcome,
      outcome_reason: action.outcome_reason,
      scheduled_at: action.scheduled_at,
      executed_at: action.executed_at,
      completed_at: action.completed_at,
      inserted_at: action.inserted_at,
      updated_at: action.updated_at
    }
  end

  defp action_id do
    @action_prefix <> random_suffix()
  end

  defp fingerprint(values, prefix) do
    hash =
      :crypto.hash(:sha256, Enum.intersperse(values, <<0>>))
      |> Base.encode16(case: :lower)

    prefix <> "-" <> binary_part(hash, 0, 16)
  end

  defp random_suffix do
    5
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
