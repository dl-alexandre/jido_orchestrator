defmodule JX.OperationPolicy do
  @moduledoc """
  Safety policy for executable operator recommendations.
  """

  @release_rules [
    %{
      action: "commit",
      decision: "allowed",
      confirmation: "not-required",
      reason: "non-destructive local commit is allowed when scope is clear and tests are green"
    },
    %{
      action: "push",
      decision: "allowed",
      confirmation: "not-required",
      reason: "non-destructive push is allowed when branch/scope is clear and tests are green"
    },
    %{
      action: "pull-request",
      decision: "allowed",
      confirmation: "not-required",
      reason:
        "opening or updating a draft PR is allowed after a coherent diff and green local checks"
    },
    %{
      action: "rerun-ci",
      decision: "allowed",
      confirmation: "not-required",
      reason: "CI reruns are allowed when they do not mutate code or secrets"
    },
    %{
      action: "force-push",
      decision: "hold",
      confirmation: "required",
      reason: "force-push can rewrite shared history"
    },
    %{
      action: "deploy",
      decision: "hold",
      confirmation: "required",
      reason: "deployments can affect public/runtime systems"
    },
    %{
      action: "release",
      decision: "hold",
      confirmation: "required",
      reason: "public releases need explicit approval"
    },
    %{
      action: "credentials",
      decision: "hold",
      confirmation: "required",
      reason: "credential changes need explicit approval"
    },
    %{
      action: "destructive-delete",
      decision: "hold",
      confirmation: "required",
      reason: "destructive deletes need explicit approval"
    }
  ]

  @safety_tiers [
    %{
      id: "inspect",
      title: "Inspect Only",
      autonomy: "autonomous",
      confirmation: "not-required",
      boundary: "read current state, capture observations, and summarize evidence",
      examples: [
        "call brief",
        "portfolio summary",
        "monitor scan",
        "session capture",
        "orchestrator review"
      ],
      blocked_by: []
    },
    %{
      id: "safe",
      title: "Safe Automation",
      autonomy: "autonomous",
      confirmation: "not-required",
      boundary: "persist profile updates, observations, notifications, and action audit records",
      examples: [
        "auto-plan a profile prompt",
        "mark a drafted prompt ready",
        "record watch results",
        "refresh observations"
      ],
      blocked_by: [
        "ambiguous target",
        "policy errors",
        "invalid profile state"
      ]
    },
    %{
      id: "gated",
      title: "Gated Live Session Action",
      autonomy: "agent-with-gate",
      confirmation: "execute-required",
      boundary: "send input only to task-owned or managed sessions after a fresh capture",
      examples: [
        "send ready profile prompt",
        "force-probe a ref-backed remote shell pane"
      ],
      blocked_by: [
        "protected session",
        "ignored session",
        "unmanaged session",
        "stale or missing capture",
        "agent UI instead of shell prompt"
      ]
    },
    %{
      id: "manual",
      title: "Manual Operator Decision",
      autonomy: "operator-needed",
      confirmation: "human-review",
      boundary:
        "require explicit judgment before changing ownership, strategy, or sensitive state",
      examples: [
        "mark a discovered session managed",
        "adopt a session",
        "stream-adopt a process-only agent",
        "resolve blocked profile strategy",
        "decide delegation integration",
        "apply call handoff"
      ],
      blocked_by: [
        "ambiguous ownership",
        "missing evidence",
        "repo/runtime blocker",
        "operator preference"
      ]
    },
    %{
      id: "held-release",
      title: "Held Release Or Destructive Action",
      autonomy: "operator-required",
      confirmation: "explicit-approval-required",
      boundary: "hold public, credential, destructive, or history-rewriting actions",
      examples: [
        "force-push",
        "deploy",
        "release",
        "credential change",
        "destructive delete"
      ],
      blocked_by: [
        "shared history risk",
        "public/runtime impact",
        "secret exposure risk",
        "irreversible deletion"
      ]
    }
  ]

  def release_rules, do: @release_rules
  def safety_tiers, do: @safety_tiers

  def policy_overview(operator_profile \\ %{}) do
    %{
      generated_at: DateTime.utc_now(),
      operator: operator_profile,
      safety_tiers: @safety_tiers,
      release_rules: @release_rules,
      defaults: %{
        commit_push_pr:
          "allowed when scope is clear, tests are green, and action is non-destructive",
        hold_for:
          "force-push, destructive deletes, credential changes, public releases/deploys, broad ambiguous scope, or protected/ignored sessions"
      }
    }
  end

  def classify_release_action(action) do
    normalized = normalize_action(action)

    Enum.find(
      @release_rules,
      %{action: normalized, decision: "hold", confirmation: "required", reason: "unknown action"},
      fn rule ->
        rule.action == normalized
      end
    )
  end

  def authorize_gated(%{action: "capture-before-force-probe", kind: "remote", ref: ref})
      when ref not in [nil, ""] do
    :ok
  end

  def authorize_gated(%{action: "capture-before-force-probe", kind: "remote"}) do
    {:skip, "force probe recommendation is not linked to a session ref"}
  end

  def authorize_gated(%{action: "capture-before-force-probe"}) do
    {:skip, "force probe execution is only available for remote discovery recommendations"}
  end

  def authorize_gated(_recommendation) do
    {:skip, "gated execution for this action is not implemented"}
  end

  def authorize_directive(session, freshness, opts \\ []) do
    cond do
      Map.get(session, :control_mode) == "protected" ->
        {:error, {:directive_policy_denied, "session is protected"}}

      Map.get(session, :control_mode) == "ignored" ->
        {:error, {:directive_policy_denied, "session is ignored"}}

      not directive_owned?(session) ->
        {:error,
         {:directive_policy_denied,
          "session is not managed; mark it managed or adopt it before sending"}}

      not fresh_enough?(freshness, opts) ->
        {:error, {:directive_policy_denied, "fresh capture required before sending"}}

      true ->
        :ok
    end
  end

  defp directive_owned?(%{type: "task"}), do: true
  defp directive_owned?(%{control_mode: "managed"}), do: true
  defp directive_owned?(_session), do: false

  defp fresh_enough?(%{status: "ok"}, _opts), do: true

  defp fresh_enough?(%{capture_status: "ok", observed_at: %DateTime{} = observed_at}, opts) do
    max_age_seconds = Keyword.get(opts, :max_capture_age_seconds, 300)
    DateTime.diff(DateTime.utc_now(), observed_at, :second) <= max_age_seconds
  end

  defp fresh_enough?(_freshness, _opts), do: false

  defp normalize_action(action) do
    action
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", "-")
  end
end
