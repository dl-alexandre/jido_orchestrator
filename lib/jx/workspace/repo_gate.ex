defmodule JX.Workspace.RepoGate do
  @moduledoc """
  Deterministic readiness gate for repo doctor state.

  The gate consumes an existing repo doctor instance or repo_state map and turns
  it into an allow/block decision. It does not observe the filesystem, SSH, Git,
  or GitHub directly.
  """

  @allowed_api_statuses ~w(ok unknown)

  def evaluate(%{} = state) do
    reasons =
      [
        reconciliation_reason(state),
        trust_reason(state),
        confidence_reason(state),
        drift_reason(state),
        fetch_reason(state),
        push_reason(state),
        api_reason(state)
      ]
      |> Enum.reject(&is_nil/1)

    eligible = reasons == []

    %{
      eligible: eligible,
      status: if(eligible, do: "allowed", else: "blocked"),
      reasons: reasons,
      required_fixes: required_fixes(reasons)
    }
  end

  def evaluate(_state) do
    %{
      eligible: false,
      status: "blocked",
      reasons: ["invalid_repo_state"],
      required_fixes: ["Rerun repo doctor and retry the gate."]
    }
  end

  defp reconciliation_reason(state) do
    case status_value(state, :reconciliation_status) do
      "reconciled" -> nil
      "unknown" -> "unknown_reconciliation"
      "drifted" -> "drifted_reconciliation"
      _other -> "unreconciled"
    end
  end

  defp trust_reason(state) do
    case status_value(state, :trust_status) do
      "trusted" -> nil
      "degraded" -> "degraded_auth"
      "untrusted" -> "untrusted_repo"
      _other -> "untrusted_repo"
    end
  end

  defp confidence_reason(state) do
    case status_value(state, :confidence) do
      "high" -> nil
      "partial" -> "partial_confidence"
      "low" -> "low_confidence"
      "unknown" -> "unknown_confidence"
      _other -> "insufficient_confidence"
    end
  end

  defp drift_reason(state) do
    case drift_status(state) do
      "none" -> nil
      "unknown" -> "unknown_drift"
      status -> "#{status}_drift"
    end
  end

  defp fetch_reason(state) do
    case auth_status(state, :fetch_allowed) do
      "ok" -> nil
      "failed" -> "fetch_failed"
      "unknown" -> "fetch_not_verified"
      _other -> "fetch_not_allowed"
    end
  end

  defp push_reason(state) do
    case auth_status(state, :push_allowed) do
      "ok" -> nil
      "failed" -> "push_failed"
      "unknown" -> "push_not_verified"
      _other -> "push_not_allowed"
    end
  end

  defp api_reason(state) do
    api_status = auth_status(state, :api_allowed)

    if api_status in @allowed_api_statuses do
      nil
    else
      case api_status do
        "failed" -> "api_failed"
        _other -> "api_not_allowed"
      end
    end
  end

  defp required_fixes([]), do: []

  defp required_fixes(reasons) do
    []
    |> maybe_add_fix(
      Enum.any?(reasons, &(&1 in ["unknown_reconciliation", "drifted_reconciliation"])),
      "Reconcile the repository and rerun repo doctor."
    )
    |> maybe_add_fix(
      Enum.any?(reasons, &String.ends_with?(&1, "_drift")),
      "Reconcile repository drift and rerun repo doctor."
    )
    |> maybe_add_fix(
      Enum.any?(
        reasons,
        &(&1 in [
            "degraded_auth",
            "fetch_failed",
            "fetch_not_verified",
            "fetch_not_allowed",
            "push_failed",
            "push_not_verified",
            "push_not_allowed",
            "api_failed",
            "api_not_allowed"
          ])
      ),
      "Restore GitHub auth and rerun repo doctor."
    )
    |> maybe_add_fix(
      Enum.any?(
        reasons,
        &(&1 in [
            "partial_confidence",
            "low_confidence",
            "unknown_confidence",
            "insufficient_confidence"
          ])
      ),
      "Restore high-confidence repo doctor evidence and rerun repo doctor."
    )
    |> maybe_add_fix(
      "untrusted_repo" in reasons,
      "Restore trusted repo evidence and rerun repo doctor."
    )
  end

  defp maybe_add_fix(fixes, true, fix), do: Enum.uniq(fixes ++ [fix])
  defp maybe_add_fix(fixes, false, _fix), do: fixes

  defp drift_status(state) do
    state
    |> state_map(:drift)
    |> field(:status, "unknown")
    |> normalize_status()
  end

  defp auth_status(state, key) do
    state
    |> state_map(:auth)
    |> field(key, "unknown")
    |> normalize_status()
  end

  defp status_value(state, key) do
    state
    |> field(key, state |> repo_state() |> field(key, "unknown"))
    |> normalize_status()
  end

  defp state_map(state, key) do
    field(state, key, field(repo_state(state), key, %{}))
  end

  defp repo_state(state), do: field(state, :repo_state, state)

  defp field(map, key, default) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, to_string(key)) -> Map.get(map, to_string(key))
      true -> default
    end
  end

  defp field(_value, _key, default), do: default

  defp normalize_status(value) when value in [nil, ""], do: "unknown"
  defp normalize_status(value), do: value |> to_string() |> String.trim() |> blank_to_unknown()

  defp blank_to_unknown(""), do: "unknown"
  defp blank_to_unknown(value), do: value
end
