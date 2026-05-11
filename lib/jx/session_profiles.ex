defmodule JX.SessionProfiles do
  @moduledoc """
  Persistent profiles and computed profile reports for orchestration sessions.

  Profiles hold intent: what a session is for, when it should be done, and the
  next prompt that is chambered. Reports compare that intent to the latest
  observed dossier so an agent can decide whether to observe, prompt, unblock,
  or revise the plan.
  """

  import Ecto.Query

  alias JX.Repo
  alias JX.BlockedReasons
  alias JX.SessionProfiles.OperatorProfile
  alias JX.SessionProfiles.SessionProfile

  @default_operator %{
    key: "default",
    source: "default",
    name: "",
    preferences:
      "Agent-led orchestration. Prefer autonomous progress, keep direct session sends gated, resolve repo/runtime blockers before prompting, and keep compact handoffs.",
    working_style:
      "Start from live observations, compare against saved intent, update profiles when reality changes, and only send prompts to managed/directable sessions.",
    escalation_policy:
      "Ask before destructive actions, broad pushes, credential changes, or directing protected/ignored sessions.",
    notes: "",
    updated_at: nil
  }

  def prompt_statuses, do: SessionProfile.prompt_statuses()

  def upsert_session_profile(ref, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:ref, ref)
      |> Map.put_new(:last_seen_at, DateTime.utc_now())

    profile = Repo.get_by(SessionProfile, ref: ref) || %SessionProfile{ref: ref}

    profile
    |> SessionProfile.changeset(attrs)
    |> Repo.insert_or_update()
  end

  def upsert_operator_profile(attrs, key \\ "default") do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:profile_key, key)

    profile = Repo.get_by(OperatorProfile, profile_key: key) || %OperatorProfile{profile_key: key}

    profile
    |> OperatorProfile.changeset(attrs)
    |> Repo.insert_or_update()
  end

  def get_operator_profile(key \\ "default") do
    key
    |> operator_profile()
    |> operator_summary()
  end

  def build_report(dossier_report, opts \\ []) do
    prompt_status = Keyword.get(opts, :prompt_status)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    operator = get_operator_profile(Keyword.get(opts, :operator_key, "default"))
    profiles_by_ref = profiles_by_ref(Enum.map(dossier_report.dossiers, & &1.ref))

    session_profiles =
      dossier_report.dossiers
      |> Enum.map(&profile_entry(&1, Map.get(profiles_by_ref, &1.ref), now))
      |> filter_prompt_status(prompt_status)

    %{
      generated_at: dossier_report.generated_at,
      observed: dossier_report.observed,
      observation_refresh: dossier_report.observation_refresh,
      operator: operator,
      total: length(session_profiles),
      profiles: session_profiles,
      errors: dossier_report.errors
    }
  end

  def apply_queue_overrides(dossiers) do
    profiles_by_ref = profiles_by_ref(Enum.map(dossiers, & &1.ref))

    Enum.map(dossiers, fn dossier ->
      case Map.get(profiles_by_ref, dossier.ref) do
        %SessionProfile{lifecycle_status: status} when status in ["done", "parked"] ->
          put_in(dossier, [:next_action], %{
            action: "none",
            priority: "low",
            safety: "inspect",
            reason: "profile lifecycle is #{status}"
          })

        %SessionProfile{prompt_status: "blocked"} ->
          put_in(dossier, [:next_action], %{
            action: "blocked-profile",
            priority: "normal",
            safety: "manual",
            reason: "profile prompt is blocked"
          })

        %SessionProfile{prompt_status: "draft"} ->
          put_in(dossier, [:next_action], %{
            action: "draft-profile",
            priority: "normal",
            safety: "safe",
            reason: draft_profile_reason(dossier)
          })

        %SessionProfile{prompt_status: "sent"} ->
          put_in(dossier, [:next_action], %{
            action: "observe",
            priority: "normal",
            safety: "inspect",
            reason: "profile prompt was sent; observe before sending again"
          })

        _profile ->
          dossier
      end
    end)
  end

  defp draft_profile_reason(%{work_state: "running"}) do
    "profile prompt is drafted; wait for session to stop running before marking ready"
  end

  defp draft_profile_reason(_dossier), do: "profile prompt is drafted; review or mark ready"

  def session_profile_summary(nil) do
    %{
      source: "inferred",
      summary: "",
      objective: "",
      expected_completion: "",
      next_prompt: "",
      prompt_status: "none",
      strategy: "",
      notes: "",
      owner: "",
      risk_level: "normal",
      lifecycle_status: "active",
      current_hypothesis: "",
      last_evidence: "",
      stale_after_seconds: nil,
      last_seen_at: nil,
      updated_at: nil
    }
  end

  def session_profile_summary(%SessionProfile{} = profile) do
    %{
      source: "stored",
      summary: profile.summary || "",
      objective: profile.objective || "",
      expected_completion: profile.expected_completion || "",
      next_prompt: profile.next_prompt || "",
      prompt_status: profile.prompt_status || "none",
      strategy: profile.strategy || "",
      notes: profile.notes || "",
      owner: profile.owner || "",
      risk_level: profile.risk_level || "normal",
      lifecycle_status: profile.lifecycle_status || "active",
      current_hypothesis: profile.current_hypothesis || "",
      last_evidence: profile.last_evidence || "",
      stale_after_seconds: profile.stale_after_seconds,
      last_seen_at: format_time(profile.last_seen_at),
      updated_at: format_time(profile.updated_at)
    }
  end

  defp profiles_by_ref([]), do: %{}

  defp profiles_by_ref(refs) do
    SessionProfile
    |> where([profile], profile.ref in ^refs)
    |> Repo.all()
    |> Map.new(&{&1.ref, &1})
  end

  defp operator_profile(key), do: Repo.get_by(OperatorProfile, profile_key: key)

  defp operator_summary(nil), do: @default_operator

  defp operator_summary(%OperatorProfile{} = profile) do
    %{
      key: profile.profile_key,
      source: "stored",
      name: profile.name || "",
      preferences: profile.preferences || "",
      working_style: profile.working_style || "",
      escalation_policy: profile.escalation_policy || "",
      notes: profile.notes || "",
      updated_at: format_time(profile.updated_at)
    }
  end

  defp profile_entry(dossier, stored_profile, now) do
    profile = session_profile_summary(stored_profile)
    actual = actual_summary(dossier)
    planned = planned_summary(profile)
    gaps = profile_gaps(dossier, profile)
    comparison = comparison_summary(dossier, profile, gaps)
    timing = timing_summary(dossier, profile, now)
    next_step = next_step(dossier, profile, comparison)

    entry = %{
      ref: dossier.ref,
      session: session_identity(dossier),
      planned: planned,
      actual: actual,
      comparison: comparison,
      timing: timing,
      next_prompt: next_prompt_summary(dossier, profile),
      next_step: next_step,
      coordination: coordination_summary(dossier, profile, comparison, next_step),
      handoff: dossier.handoff
    }

    blocked = BlockedReasons.classify(entry)

    entry
    |> Map.put(:blocked, blocked)
    |> put_in([:coordination, :blocked_reason], blocked.primary)
    |> put_in([:coordination, :blocked_reasons], blocked.reasons)
    |> put_in([:coordination, :urgent_blocked], blocked.urgent)
  end

  defp session_identity(dossier) do
    %{
      host: dossier.host,
      type: dossier.type,
      kind: dossier.kind,
      agent_name: dossier.agent_name,
      project: dossier.project,
      control_mode: dossier.control_mode,
      can_direct: dossier.can_direct,
      pane: dossier.pane,
      current_path: dossier.current_path,
      tmux_server: dossier.tmux_server,
      session_name: dossier.session_name,
      window: dossier.window,
      pane_index: dossier.pane_index
    }
  end

  defp planned_summary(profile) do
    %{
      source: profile.source,
      summary: profile.summary,
      objective: profile.objective,
      expected_completion: profile.expected_completion,
      strategy: profile.strategy,
      notes: profile.notes,
      owner: profile.owner,
      risk_level: profile.risk_level,
      lifecycle_status: profile.lifecycle_status,
      current_hypothesis: profile.current_hypothesis,
      last_evidence: profile.last_evidence,
      stale_after_seconds: profile.stale_after_seconds,
      prompt_status: profile.prompt_status,
      updated_at: profile.updated_at,
      last_seen_at: profile.last_seen_at
    }
  end

  defp actual_summary(dossier) do
    %{
      task: dossier.task,
      summary: dossier.summary,
      title: dossier.title,
      work_state: dossier.work_state,
      capture_status: dossier.capture_status,
      directive_state: dossier.directive_state,
      last_directive: dossier.last_directive,
      change: dossier.change,
      next_action: dossier.next_action,
      repo: dossier.repo
    }
  end

  defp timing_summary(dossier, profile, now) do
    observed_at = get_in(dossier, [:change, :observed_at])
    profile_updated_at = profile.updated_at
    last_seen_at = profile.last_seen_at
    stale_after_seconds = profile.stale_after_seconds
    observation_age_seconds = seconds_since(observed_at, now)
    profile_age_seconds = seconds_since(profile_updated_at, now)
    last_seen_age_seconds = seconds_since(last_seen_at, now)

    stale =
      stale_after_seconds != nil and
        stale_reference_age(observation_age_seconds, last_seen_age_seconds) > stale_after_seconds

    %{
      observed_at: observed_at,
      last_observation_age_seconds: observation_age_seconds,
      profile_updated_at: profile_updated_at,
      profile_update_age_seconds: profile_age_seconds,
      last_seen_at: last_seen_at,
      last_seen_age_seconds: last_seen_age_seconds,
      stale_after_seconds: stale_after_seconds,
      stale: stale,
      check_status: check_status(stale, observation_age_seconds, profile.prompt_status),
      next_check: next_check(stale, observation_age_seconds, profile.prompt_status)
    }
  end

  defp stale_reference_age(observation_age_seconds, last_seen_age_seconds) do
    cond do
      is_integer(observation_age_seconds) -> observation_age_seconds
      is_integer(last_seen_age_seconds) -> last_seen_age_seconds
      true -> 0
    end
  end

  defp check_status(true, _observation_age_seconds, _prompt_status), do: "stale"
  defp check_status(_stale, _observation_age_seconds, "sent"), do: "awaiting-response"
  defp check_status(_stale, nil, _prompt_status), do: "unobserved"
  defp check_status(_stale, _observation_age_seconds, _prompt_status), do: "fresh"

  defp next_check(true, _observation_age_seconds, _prompt_status), do: "observe session now"

  defp next_check(_stale, _observation_age_seconds, "sent"),
    do: "observe after directive age gate"

  defp next_check(_stale, nil, _prompt_status), do: "capture initial observation"

  defp next_check(_stale, _observation_age_seconds, _prompt_status),
    do: "continue scheduled monitoring"

  defp seconds_since(nil, _now), do: nil
  defp seconds_since("", _now), do: nil

  defp seconds_since(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.diff(now, datetime, :second)
      {:error, _reason} -> nil
    end
  end

  defp seconds_since(%DateTime{} = value, now), do: DateTime.diff(now, value, :second)
  defp seconds_since(_value, _now), do: nil

  defp next_prompt_summary(dossier, profile) do
    cond do
      profile.lifecycle_status in ["done", "parked"] ->
        %{source: "none", status: "none", text: ""}

      present?(profile.next_prompt) ->
        %{source: "profile", status: profile.prompt_status, text: profile.next_prompt}

      profile.prompt_status in ["blocked", "sent", "ready"] ->
        %{source: "profile", status: profile.prompt_status, text: ""}

      attention_state?(dossier) ->
        %{source: "none", status: "none", text: ""}

      present?(get_in(dossier, [:handoff, :suggested_message])) ->
        %{
          source: "suggested",
          status: "draft",
          text: dossier.handoff.suggested_message
        }

      send_candidate?(dossier) ->
        %{
          source: "suggested",
          status: "draft",
          text: "Report current status, blockers, changed files, and the next concrete step."
        }

      true ->
        %{source: "none", status: "none", text: ""}
    end
  end

  defp comparison_summary(dossier, profile, gaps) do
    %{
      state: comparison_state(dossier, profile, gaps),
      gaps: gaps,
      expected_completion: profile.expected_completion,
      actual_work_state: dossier.work_state,
      actual_summary: first_present([dossier.summary, dossier.task, dossier.title]),
      repo_blockers: dossier.repo.blockers,
      repo_risks: dossier.repo.risks
    }
  end

  defp comparison_state(_dossier, %{lifecycle_status: "done"}, _gaps), do: "done"

  defp comparison_state(_dossier, %{lifecycle_status: "parked"}, _gaps), do: "parked"

  defp comparison_state(dossier, _profile, _gaps) when dossier.repo.blockers != [] do
    "blocked"
  end

  defp comparison_state(_dossier, %{prompt_status: "blocked"}, _gaps) do
    "blocked"
  end

  defp comparison_state(dossier, profile, _gaps)
       when dossier.directive_state == "sent-awaiting-observation" or
              profile.prompt_status == "sent" do
    "awaiting-observation"
  end

  defp comparison_state(dossier, profile, _gaps)
       when profile.prompt_status == "ready" and dossier.can_direct do
    "ready-to-send"
  end

  defp comparison_state(dossier, _profile, gaps) do
    cond do
      "missing objective" in gaps -> "needs-profile"
      attention_state?(dossier) -> "needs-attention"
      "missing next prompt" in gaps and send_candidate?(dossier) -> "needs-prompt"
      true -> "tracking"
    end
  end

  defp profile_gaps(dossier, profile) do
    if profile.lifecycle_status in ["done", "parked"] do
      []
    else
      active_profile_gaps(dossier, profile)
    end
  end

  defp active_profile_gaps(dossier, profile) do
    []
    |> maybe_gap(not present?(profile.objective), "missing objective")
    |> maybe_gap(not present?(profile.expected_completion), "missing expected completion")
    |> maybe_gap(
      profile.prompt_status != "blocked" and send_candidate?(dossier) and
        not present?(profile.next_prompt),
      "missing next prompt"
    )
    |> maybe_gap(
      dossier.repo.blockers != [],
      "repo blocker: #{Enum.join(dossier.repo.blockers, ",")}"
    )
    |> maybe_gap(dossier.repo.risks != [], "repo risk: #{Enum.join(dossier.repo.risks, ",")}")
    |> maybe_gap(dossier.directive_state == "sent-awaiting-observation", "awaiting observation")
    |> Enum.reverse()
  end

  defp maybe_gap(gaps, true, gap), do: [gap | gaps]
  defp maybe_gap(gaps, false, _gap), do: gaps

  defp next_step(dossier, profile, comparison) do
    cond do
      comparison.state == "done" ->
        "done"

      comparison.state == "parked" ->
        "parked: #{truncate(first_present([profile.objective, profile.summary]), 96)}"

      comparison.state == "blocked" ->
        blocked_next_step(dossier, profile)

      comparison.state == "ready-to-send" ->
        "send chambered prompt"

      comparison.state == "awaiting-observation" ->
        "observe before sending another prompt"

      comparison.state == "needs-attention" ->
        "inspect attention state"

      dossier.work_state == "running" ->
        "observe active work"

      present?(profile.next_prompt) and send_candidate?(dossier) ->
        "review chambered prompt and mark ready"

      send_candidate?(dossier) ->
        "draft next prompt from actual session state"

      true ->
        dossier.next_action.action
    end
  end

  defp blocked_next_step(%{repo: %{blockers: blockers}}, _profile) when blockers != [] do
    "resolve repo/runtime blocker before prompting"
  end

  defp blocked_next_step(_dossier, %{prompt_status: "blocked"} = profile) do
    case first_present([profile.next_prompt, profile.objective, profile.summary]) do
      "" -> "blocked pending strategy"
      reason -> "blocked: #{truncate(reason, 96)}"
    end
  end

  defp blocked_next_step(_dossier, _profile), do: "resolve blocker before prompting"

  defp coordination_summary(dossier, profile, comparison, next_step) do
    operator_reason = operator_needed_reason(dossier, profile, comparison)
    operator_needed = operator_reason != ""
    mode = coordination_mode(dossier, profile, comparison, operator_needed)

    %{
      mode: mode,
      agent_can_continue: agent_can_continue?(mode, operator_needed),
      operator_needed: operator_needed,
      operator_reason: operator_reason,
      review_required: mode == "agent-review",
      next_agent_action: next_agent_action(operator_needed, operator_reason, next_step)
    }
  end

  defp operator_needed_reason(dossier, profile, comparison) do
    cond do
      dossier.control_mode == "ignored" ->
        ""

      profile.lifecycle_status == "blocked" ->
        "profile lifecycle is blocked"

      profile.prompt_status == "blocked" ->
        "profile prompt is blocked"

      dossier.repo.blockers != [] ->
        "repo/runtime blocker: #{Enum.join(dossier.repo.blockers, ",")}"

      comparison.state == "needs-attention" and not dossier.can_direct ->
        "attention session is not directable: #{dossier.reason}"

      get_in(dossier, [:next_action, :safety]) == "manual" ->
        "manual session action required: #{get_in(dossier, [:next_action, :action])}"

      comparison.state == "needs-profile" and dossier.control_mode == "managed" ->
        "session needs objective and expected completion"

      true ->
        ""
    end
  end

  defp coordination_mode(_dossier, _profile, _comparison, true), do: "operator-needed"
  defp coordination_mode(%{control_mode: "ignored"}, _profile, _comparison, false), do: "ignored"
  defp coordination_mode(_dossier, _profile, %{state: "done"}, false), do: "done"
  defp coordination_mode(_dossier, _profile, %{state: "parked"}, false), do: "parked"

  defp coordination_mode(_dossier, _profile, %{state: "ready-to-send"}, false) do
    "agent-review"
  end

  defp coordination_mode(_dossier, %{prompt_status: "draft"}, _comparison, false) do
    "agent-review"
  end

  defp coordination_mode(_dossier, _profile, %{state: "needs-attention"}, false) do
    "agent-review"
  end

  defp coordination_mode(_dossier, _profile, %{state: "awaiting-observation"}, false) do
    "autonomous-monitoring"
  end

  defp coordination_mode(%{work_state: "running"}, _profile, _comparison, false) do
    "autonomous-monitoring"
  end

  defp coordination_mode(_dossier, _profile, _comparison, false), do: "autonomous"

  defp agent_can_continue?(_mode, true), do: false
  defp agent_can_continue?(mode, false), do: mode not in ["done", "parked", "ignored"]

  defp next_agent_action(true, reason, _next_step), do: "wait for operator: #{reason}"
  defp next_agent_action(false, _reason, next_step), do: next_step

  defp filter_prompt_status(entries, nil), do: entries

  defp filter_prompt_status(entries, prompt_status) do
    Enum.filter(entries, &(get_in(&1, [:planned, :prompt_status]) == prompt_status))
  end

  defp send_candidate?(%{work_state: "running"}), do: false

  defp send_candidate?(dossier) do
    get_in(dossier, [:next_action, :action]) == "send-session" and not attention_state?(dossier)
  end

  defp attention_state?(%{work_state: "waiting"} = dossier), do: needs_attention?(dossier)
  defp attention_state?(_dossier), do: false

  defp needs_attention?(dossier) do
    get_in(dossier, [:change, :needs_attention]) == true
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp first_present(values) do
    Enum.find_value(values, "", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end)
  end

  defp truncate(value, max_size) when byte_size(value) <= max_size, do: value
  defp truncate(value, max_size), do: binary_part(value, 0, max_size) <> "..."

  defp format_time(nil), do: nil
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
