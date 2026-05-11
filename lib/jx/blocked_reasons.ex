defmodule JX.BlockedReasons do
  @moduledoc """
  Classifies why a session is blocked, parked, or merely carrying non-urgent risk.
  """

  def classify(%{blocked: %{primary: primary, reasons: reasons, urgent: urgent}} = _profile)
      when is_binary(primary) and is_list(reasons) and is_boolean(urgent) do
    %{primary: primary, urgent: urgent, reasons: reasons, counts: count_reasons(reasons)}
  end

  def classify(profile) do
    reasons =
      if terminal?(profile) do
        terminal_reasons(profile)
      else
        active_reasons(profile)
      end

    %{
      primary: primary_category(reasons),
      urgent: Enum.any?(reasons, & &1.urgent),
      reasons: reasons,
      counts: count_reasons(reasons)
    }
  end

  def urgent?(profile), do: classify(profile).urgent

  def parked?(profile) do
    lifecycle_status(profile) == "parked" or comparison_state(profile) == "parked"
  end

  def done?(profile) do
    lifecycle_status(profile) == "done" or comparison_state(profile) == "done"
  end

  def counts(profiles) do
    profiles
    |> Enum.map(&classify(&1).primary)
    |> Enum.reject(&(&1 in ["", "none"]))
    |> Enum.frequencies()
  end

  def urgent_counts(profiles) do
    profiles
    |> Enum.map(&classify/1)
    |> Enum.filter(& &1.urgent)
    |> Enum.map(& &1.primary)
    |> Enum.reject(&(&1 in ["", "none"]))
    |> Enum.frequencies()
  end

  defp terminal?(profile), do: done?(profile) or parked?(profile)

  defp terminal_reasons(profile) do
    cond do
      done?(profile) ->
        [reason("done", "info", false, "profile lifecycle is done")]

      parked?(profile) ->
        [reason("parked", "info", false, "profile lifecycle is parked")]

      true ->
        []
    end
  end

  defp active_reasons(profile) do
    repo_blockers = list_value(profile, [:comparison, :repo_blockers])
    repo_risks = list_value(profile, [:comparison, :repo_risks])
    operator_reason = text_value(profile, [:coordination, :operator_reason])

    []
    |> maybe_reason(
      lifecycle_status(profile) == "blocked",
      "lifecycle-blocked",
      "warning",
      true,
      "profile lifecycle is blocked"
    )
    |> maybe_reason(
      prompt_blocked?(profile),
      "prompt-blocked",
      "warning",
      true,
      "profile prompt is blocked"
    )
    |> maybe_reason(
      repo_blockers != [],
      "repo-blocker",
      "warning",
      true,
      "repo/runtime blocker: #{Enum.join(repo_blockers, ",")}"
    )
    |> maybe_reason(
      comparison_state(profile) == "blocked" and repo_blockers == [] and
        not prompt_blocked?(profile),
      "blocked",
      "warning",
      true,
      first_present([operator_reason, text_value(profile, [:next_step]), "blocked"])
    )
    |> maybe_reason(
      repo_risks != [],
      "repo-risk",
      "notice",
      false,
      "repo risk: #{Enum.join(repo_risks, ",")}"
    )
    |> maybe_reason(
      stale?(profile),
      "stale-profile",
      "notice",
      false,
      "profile or observation is stale"
    )
    |> maybe_reason(
      attention_not_directable?(profile),
      "attention-not-directable",
      "warning",
      true,
      first_present([operator_reason, "attention session is not directable"])
    )
    |> maybe_reason(
      manual_action?(operator_reason),
      "manual-action",
      "warning",
      true,
      operator_reason
    )
    |> maybe_reason(
      missing_profile?(profile),
      "missing-profile",
      "notice",
      false,
      "session needs objective and expected completion"
    )
    |> Enum.reverse()
  end

  defp maybe_reason(reasons, true, category, severity, urgent, summary) do
    [reason(category, severity, urgent, summary) | reasons]
  end

  defp maybe_reason(reasons, false, _category, _severity, _urgent, _summary), do: reasons

  defp reason(category, severity, urgent, summary) do
    %{
      category: category,
      severity: severity,
      urgent: urgent,
      summary: summary || ""
    }
  end

  defp primary_category([]), do: "none"
  defp primary_category([reason | _rest]), do: reason.category

  defp count_reasons(reasons), do: Enum.frequencies_by(reasons, & &1.category)

  defp lifecycle_status(profile), do: text_value(profile, [:planned, :lifecycle_status])
  defp comparison_state(profile), do: text_value(profile, [:comparison, :state])

  defp prompt_blocked?(profile) do
    text_value(profile, [:planned, :prompt_status]) == "blocked" or
      text_value(profile, [:next_prompt, :status]) == "blocked"
  end

  defp stale?(profile), do: get(profile, [:timing, :stale]) == true

  defp attention_not_directable?(profile) do
    comparison_state(profile) == "needs-attention" and
      get(profile, [:session, :can_direct]) != true
  end

  defp manual_action?(operator_reason) do
    String.starts_with?(operator_reason, "manual session action required")
  end

  defp missing_profile?(profile) do
    comparison_state(profile) == "needs-profile" and
      text_value(profile, [:session, :control_mode]) == "managed"
  end

  defp list_value(profile, path) do
    case get(profile, path) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp text_value(profile, path) do
    case get(profile, path) do
      value when is_binary(value) -> value
      _value -> ""
    end
  end

  defp get(value, []), do: value

  defp get(value, [key | rest]) when is_map(value) do
    value
    |> Map.get(key, Map.get(value, to_string(key)))
    |> get(rest)
  end

  defp get(_value, _path), do: nil

  defp first_present(values) do
    Enum.find_value(values, "", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end)
  end
end
