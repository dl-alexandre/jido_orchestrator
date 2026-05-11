defmodule JX.CallBrief do
  @moduledoc """
  Builds compact call and meeting briefs from orchestration state.

  This module intentionally has no audio, browser, or telephony dependency. It
  provides the shared payload a future voice, Meet, or chat adapter can read
  aloud or use as its opening control surface.
  """

  @warning_severities ~w(critical warning)

  def build(data, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    portfolio = field(data, :portfolio) || %{}
    inbox = field(data, :inbox) || %{}
    notifications = field(data, :notifications) || []
    ci_watches = field(data, :ci_watches) || []
    handoffs = field(data, :handoffs) || []
    delegation_reviews = field(data, :delegation_reviews) || []
    delegations = field(data, :delegations) || []
    heartbeats = field(data, :heartbeats) || []
    operator = field(data, :operator) || %{}
    orchestrator = orchestrator_summary(heartbeats)

    agenda =
      inbox
      |> agenda_items(notifications, ci_watches, handoffs, delegation_reviews, delegations)
      |> Enum.take(limit)

    %{
      generated_at: iso_now(),
      surface: "call",
      mode: "brief",
      headline: headline(agenda, portfolio, inbox),
      operator: operator_summary(operator),
      context:
        context_summary(
          portfolio,
          inbox,
          notifications,
          ci_watches,
          handoffs,
          delegation_reviews,
          delegations
        ),
      orchestrator: orchestrator,
      agenda: agenda,
      projects: portfolio_projects(portfolio, limit),
      notifications: Enum.map(Enum.take(notifications, limit), &notification_summary/1),
      watches: Enum.map(Enum.take(ci_watches, limit), &ci_watch_summary/1),
      delegation_reviews:
        Enum.map(Enum.take(delegation_reviews, limit), &delegation_review_summary/1),
      delegations:
        delegations
        |> Enum.filter(&active_delegation?/1)
        |> Enum.take(limit)
        |> Enum.map(&delegation_summary/1),
      handoffs: Enum.map(Enum.take(handoffs, limit), &handoff_summary/1),
      next: next_step(agenda, orchestrator)
    }
  end

  defp agenda_items(inbox, notifications, ci_watches, handoffs, delegation_reviews, delegations) do
    (notification_agenda(notifications) ++
       inbox_section_agenda(inbox, :needs_judgment, "judgment") ++
       handoff_agenda(handoffs) ++
       delegation_review_agenda(delegation_reviews) ++
       delegation_agenda(delegations) ++
       ci_watch_agenda(ci_watches) ++
       inbox_section_agenda(inbox, :ready, "ready") ++
       inbox_section_agenda(inbox, :awaiting_observation, "observe"))
    |> Enum.sort_by(&agenda_sort_key/1)
  end

  defp notification_agenda(notifications) do
    notifications
    |> Enum.filter(
      &(field(&1, :severity) in @warning_severities or field(&1, :kind) == "external.wake")
    )
    |> Enum.map(fn notification ->
      %{
        kind: "notification",
        priority: severity_priority(field(notification, :severity)),
        label:
          truncate(
            first_present([field(notification, :summary), field(notification, :kind)]),
            120
          ),
        detail:
          [field(notification, :severity), field(notification, :kind)]
          |> Enum.reject(&blank?/1)
          |> Enum.join(" "),
        ref: field(notification, :ref) || "",
        project: field(notification, :project) || "",
        id: field(notification, :notification_id) || ""
      }
    end)
  end

  defp inbox_section_agenda(inbox, section_name, kind) do
    inbox
    |> inbox_section(section_name)
    |> Enum.map(fn item ->
      %{
        kind: kind,
        priority: section_priority(kind),
        label:
          truncate(
            first_present([
              field(item, :next_step),
              field(item, :objective),
              field(item, :actual),
              field(item, :state)
            ]),
            120
          ),
        detail:
          [field(item, :state), field(item, :prompt_status), field(item, :work_state)]
          |> Enum.reject(&blank?/1)
          |> Enum.join(" "),
        ref: field(item, :ref) || "",
        project: field(item, :project) || "",
        id: field(item, :ref) || ""
      }
    end)
  end

  defp ci_watch_agenda(ci_watches) do
    ci_watches
    |> Enum.filter(&(field(&1, :status) in ["active", "failed", "cancelled", "superseded"]))
    |> Enum.uniq_by(&ci_watch_key/1)
    |> Enum.map(fn watch ->
      %{
        kind: "ci_watch",
        priority: ci_watch_priority(field(watch, :status)),
        label:
          truncate(
            first_present([
              field(watch, :last_summary),
              field(watch, :goal),
              "PR ##{field(watch, :pr_number)} #{field(watch, :status)}"
            ]),
            120
          ),
        detail:
          [field(watch, :status), field(watch, :mode), field(watch, :repo)]
          |> Enum.reject(&blank?/1)
          |> Enum.join(" "),
        ref: field(watch, :ref) || "",
        project: field(watch, :project) || "",
        id: field(watch, :watch_id) || ""
      }
    end)
  end

  defp handoff_agenda(handoffs) do
    handoffs
    |> Enum.filter(&(field(&1, :status) == "open"))
    |> Enum.map(fn handoff ->
      %{
        kind: "handoff",
        priority: 70,
        label:
          truncate(
            first_present([
              field(handoff, :title),
              field(handoff, :summary),
              field(handoff, :operator_input)
            ]),
            120
          ),
        detail: field(handoff, :surface) || "call",
        ref: field(handoff, :ref) || "",
        project: field(handoff, :project) || "",
        id: field(handoff, :handoff_id) || ""
      }
    end)
  end

  defp delegation_review_agenda(reviews) do
    reviews
    |> Enum.map(fn review ->
      decision = field(review, :decision) || "hold"

      %{
        kind: "delegation_review",
        priority: delegation_review_priority(decision),
        label:
          truncate(
            first_present([
              field(review, :summary),
              field(review, :title),
              "completed delegation awaiting review"
            ]),
            120
          ),
        detail:
          [
            decision,
            field(review, :status),
            field(review, :project)
          ]
          |> Enum.reject(&blank?/1)
          |> Enum.join(" "),
        ref: field(review, :ref) || "",
        project: field(review, :project) || "",
        id: field(review, :delegation_id) || ""
      }
    end)
  end

  defp delegation_agenda(delegations) do
    delegations
    |> Enum.filter(&active_delegation?/1)
    |> Enum.map(fn delegation ->
      status = field(delegation, :status) || "queued"
      warnings = delegation_warnings(delegation)

      %{
        kind: "delegation",
        priority: delegation_priority(status, field(delegation, :priority), warnings),
        label:
          truncate(
            first_present([
              List.first(warnings),
              field(delegation, :worker_summary),
              field(delegation, :title),
              field(delegation, :brief)
            ]),
            120
          ),
        detail:
          [
            status,
            warning_detail(warnings),
            field(delegation, :agent_kind),
            field(delegation, :owner)
          ]
          |> Enum.reject(&blank?/1)
          |> Enum.join(" "),
        ref: field(delegation, :ref) || "",
        project: field(delegation, :project) || "",
        id: field(delegation, :delegation_id) || ""
      }
    end)
  end

  defp headline([%{kind: "notification", detail: detail} | _rest], _portfolio, _inbox) do
    "Operator attention needed: #{detail}"
  end

  defp headline([%{kind: "judgment", label: label} | _rest], _portfolio, _inbox) do
    "Operator judgment needed: #{label}"
  end

  defp headline([%{kind: "ci_watch", label: label} | _rest], _portfolio, _inbox) do
    "CI watch needs review: #{label}"
  end

  defp headline([%{kind: "delegation", label: label} | _rest], _portfolio, _inbox) do
    "Delegation needs review: #{label}"
  end

  defp headline([%{kind: "delegation_review", label: label} | _rest], _portfolio, _inbox) do
    "Delegation integration needed: #{label}"
  end

  defp headline([%{kind: "handoff", label: label} | _rest], _portfolio, _inbox) do
    "Call handoff needs review: #{label}"
  end

  defp headline(_agenda, portfolio, _inbox) do
    totals = field(portfolio, :totals) || %{}
    running = integer_field(totals, :running_sessions)
    awaiting = integer_field(totals, :awaiting_observation)
    ready = integer_field(totals, :ready_sessions)

    cond do
      ready > 0 ->
        "Ready work is waiting: #{ready} session#{plural(ready)}"

      running + awaiting > 0 ->
        "Work is in motion: #{running} running, #{awaiting} awaiting observation"

      true ->
        "No urgent operator action."
    end
  end

  defp next_step([%{kind: "notification", label: label, ref: ref} | _rest], _orchestrator) do
    "Review notification#{ref_text(ref)}: #{label}"
  end

  defp next_step([%{kind: "judgment", label: label, ref: ref} | _rest], _orchestrator) do
    "Make the blocked-session decision#{ref_text(ref)}: #{label}"
  end

  defp next_step([%{kind: "ci_watch", label: label, id: watch_id} | _rest], _orchestrator) do
    "Review CI watch #{watch_id}: #{label}"
  end

  defp next_step([%{kind: "handoff", label: label, id: handoff_id} | _rest], _orchestrator) do
    "Apply or close call handoff #{handoff_id}: #{label}"
  end

  defp next_step([%{kind: "delegation", label: label, id: delegation_id} | _rest], _orchestrator) do
    "Review delegation #{delegation_id}: #{label}"
  end

  defp next_step(
         [%{kind: "delegation_review", label: label, id: delegation_id} | _rest],
         _orchestrator
       ) do
    "Decide delegation review #{delegation_id}: #{label}"
  end

  defp next_step([%{kind: "ready", label: label, ref: ref} | _rest], _orchestrator) do
    "Send or revise the chambered prompt#{ref_text(ref)}: #{label}"
  end

  defp next_step([%{kind: "observe", label: label, ref: ref} | _rest], _orchestrator) do
    "Observe the active session#{ref_text(ref)}: #{label}"
  end

  defp next_step([], orchestrator) do
    first_present([
      field(orchestrator, :autonomous_next),
      "Keep background orchestration running and wait for the next watch or session change."
    ])
  end

  defp context_summary(
         portfolio,
         inbox,
         notifications,
         ci_watches,
         handoffs,
         delegation_reviews,
         delegations
       ) do
    totals = field(portfolio, :totals) || %{}

    %{
      observed: field(portfolio, :observed) || field(inbox, :observed) || false,
      projects_total: integer_field(portfolio, :projects_total),
      sessions_total: integer_field(totals, :sessions_total),
      ready_sessions: integer_field(totals, :ready_sessions),
      blocked_sessions: integer_field(totals, :blocked_sessions),
      awaiting_observation: integer_field(totals, :awaiting_observation),
      running_sessions: integer_field(totals, :running_sessions),
      unread_notifications: Enum.count(notifications, &(field(&1, :status) in [nil, "unread"])),
      warning_notifications:
        Enum.count(notifications, &(field(&1, :severity) in @warning_severities)),
      active_ci_watches: Enum.count(ci_watches, &(field(&1, :status) == "active")),
      open_handoffs: Enum.count(handoffs, &(field(&1, :status) == "open")),
      pending_delegation_reviews: length(delegation_reviews),
      open_delegations:
        Enum.count(delegations, &(field(&1, :status) in ["queued", "running", "blocked"]))
    }
  end

  defp portfolio_projects(portfolio, limit) do
    portfolio
    |> field(:projects)
    |> List.wrap()
    |> Enum.take(limit)
    |> Enum.map(fn project ->
      %{
        name: field(project, :name) || "",
        host: field(project, :host) || "",
        sessions_total: integer_field(project, :sessions_total),
        blocked_total: integer_field(project, :blocked_total),
        ready_total: integer_field(project, :ready_total),
        awaiting_total: integer_field(project, :awaiting_total),
        running_total: integer_field(project, :running_total),
        next_action: field(project, :next_action) || "",
        focus: truncate(field(project, :focus) || "", 160),
        refs:
          project
          |> field(:refs)
          |> List.wrap()
          |> Enum.map(&field(&1, :ref))
          |> Enum.reject(&blank?/1)
      }
    end)
  end

  defp notification_summary(notification) do
    %{
      id: field(notification, :notification_id) || "",
      kind: field(notification, :kind) || "",
      severity: field(notification, :severity) || "",
      status: field(notification, :status) || "",
      ref: field(notification, :ref) || "",
      project: field(notification, :project) || "",
      summary: truncate(field(notification, :summary) || "", 160),
      updated_at: iso_time(field(notification, :updated_at))
    }
  end

  defp ci_watch_summary(watch) do
    %{
      id: field(watch, :watch_id) || "",
      status: field(watch, :status) || "",
      mode: field(watch, :mode) || "",
      repo: field(watch, :repo) || "",
      pr_number: field(watch, :pr_number),
      ref: field(watch, :ref) || "",
      project: field(watch, :project) || "",
      goal: truncate(field(watch, :goal) || "", 120),
      summary: truncate(field(watch, :last_summary) || "", 160),
      last_checked_at: iso_time(field(watch, :last_checked_at)),
      updated_at: iso_time(field(watch, :updated_at))
    }
  end

  defp handoff_summary(handoff) do
    %{
      id: field(handoff, :handoff_id) || "",
      surface: field(handoff, :surface) || "",
      status: field(handoff, :status) || "",
      project: field(handoff, :project) || "",
      ref: field(handoff, :ref) || "",
      title: truncate(field(handoff, :title) || "", 120),
      summary: truncate(field(handoff, :summary) || "", 160),
      updated_at: iso_time(field(handoff, :updated_at))
    }
  end

  defp delegation_review_summary(review) do
    %{
      id: field(review, :delegation_id) || "",
      status: field(review, :status) || "",
      decision: field(review, :decision) || "",
      project: field(review, :project) || "",
      ref: field(review, :ref) || "",
      title: truncate(field(review, :title) || "", 120),
      summary: truncate(field(review, :summary) || "", 160),
      warnings:
        review
        |> field(:warnings)
        |> List.wrap()
        |> Enum.take(5),
      evidence: field(review, :evidence) || %{},
      ownership: field(review, :ownership) || %{},
      foreground: field(review, :foreground) || %{}
    }
  end

  defp delegation_summary(delegation) do
    %{
      id: field(delegation, :delegation_id) || "",
      status: field(delegation, :status) || "",
      priority: field(delegation, :priority) || 0,
      project: field(delegation, :project) || "",
      ref: field(delegation, :ref) || "",
      owner: field(delegation, :owner) || "",
      agent_kind: field(delegation, :agent_kind) || "",
      title: truncate(field(delegation, :title) || "", 120),
      brief: truncate(field(delegation, :brief) || "", 160),
      write_paths:
        delegation
        |> field(:write_paths)
        |> json_list()
        |> Enum.take(5),
      lint_warnings:
        delegation
        |> field(:lint_warnings)
        |> json_list()
        |> Enum.take(5),
      evidence_count:
        delegation
        |> field(:evidence)
        |> json_list()
        |> length(),
      latest_evidence:
        delegation
        |> field(:evidence)
        |> json_list()
        |> List.last(),
      residual_risks:
        delegation
        |> field(:residual_risks)
        |> json_list()
        |> Enum.take(5),
      review: field(delegation, :review) || %{},
      integration_status: field(delegation, :integration_status) || "",
      integration_summary: truncate(field(delegation, :integration_summary) || "", 160),
      worker_summary: truncate(field(delegation, :worker_summary) || "", 160),
      updated_at: iso_time(field(delegation, :updated_at))
    }
  end

  defp orchestrator_summary([]) do
    %{
      status: "unknown",
      consumer: "",
      mode: "",
      last_scan_at: nil,
      next_wake_at: nil,
      top_priority: "",
      autonomous_next: "",
      operator_needed_for: []
    }
  end

  defp orchestrator_summary([heartbeat | _rest]) do
    guidance = heartbeat_guidance(heartbeat)

    %{
      status: field(heartbeat, :status) || "unknown",
      consumer: field(heartbeat, :consumer) || "",
      mode: field(heartbeat, :mode) || "",
      last_scan_at: iso_time(field(heartbeat, :last_scan_at)),
      last_decision_at: iso_time(field(heartbeat, :last_decision_at)),
      next_wake_at: iso_time(field(heartbeat, :next_wake_at)),
      top_priority: field(guidance, :top_priority) || "",
      autonomous_next: field(guidance, :autonomous_next) || "",
      operator_needed_for: field(guidance, :operator_needed_for) || [],
      counts: field(guidance, :counts) || %{},
      focus_refs: field(guidance, :focus_refs) || []
    }
  end

  defp operator_summary(operator) do
    %{
      key: field(operator, :key) || field(operator, :profile_key) || "default",
      source: field(operator, :source) || "",
      preferences: truncate(field(operator, :preferences) || "", 220),
      working_style: truncate(field(operator, :working_style) || "", 220),
      escalation_policy: truncate(field(operator, :escalation_policy) || "", 220)
    }
  end

  defp heartbeat_guidance(heartbeat) do
    case Jason.decode(field(heartbeat, :scan_snapshot) || "{}") do
      {:ok, %{"guidance" => guidance}} -> guidance
      _other -> %{}
    end
  end

  defp inbox_section(inbox, section_name) do
    inbox
    |> field(:sections)
    |> field(section_name)
    |> List.wrap()
  end

  defp section_priority("judgment"), do: 80
  defp section_priority("ready"), do: 50
  defp section_priority("observe"), do: 40
  defp section_priority(_kind), do: 10

  defp severity_priority("critical"), do: 100
  defp severity_priority("warning"), do: 90
  defp severity_priority(_severity), do: 10

  defp agenda_sort_key(item), do: {-Map.get(item, :priority, 0), Map.get(item, :kind, "")}

  defp ci_watch_priority("failed"), do: 95
  defp ci_watch_priority("cancelled"), do: 85
  defp ci_watch_priority("superseded"), do: 75
  defp ci_watch_priority("active"), do: 35
  defp ci_watch_priority(_status), do: 10

  defp delegation_priority("blocked", priority, _warnings), do: 92 + integer_value(priority)

  defp delegation_priority(_status, priority, [_warning | _rest]),
    do: 88 + integer_value(priority)

  defp delegation_priority("running", priority, _warnings), do: 55 + integer_value(priority)
  defp delegation_priority("queued", priority, _warnings), do: 45 + integer_value(priority)
  defp delegation_priority(_status, priority, _warnings), do: 10 + integer_value(priority)

  defp delegation_review_priority("reject"), do: 96
  defp delegation_review_priority("revise"), do: 93
  defp delegation_review_priority("hold"), do: 82
  defp delegation_review_priority("accept"), do: 76
  defp delegation_review_priority(_decision), do: 70

  defp delegation_warnings(delegation) do
    delegation
    |> field(:lint_warnings)
    |> json_list()
  end

  defp active_delegation?(delegation) do
    field(delegation, :status) in ["queued", "running", "blocked"]
  end

  defp warning_detail([]), do: ""
  defp warning_detail(_warnings), do: "preflight-warning"

  defp ci_watch_key(watch) do
    {field(watch, :repo), field(watch, :pr_number), field(watch, :ref)}
  end

  defp integer_field(map, key) do
    case field(map, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value)
      _value -> 0
    end
  end

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(value) when is_binary(value), do: parse_integer(value)
  defp integer_value(_value), do: 0

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> 0
    end
  end

  defp ref_text(ref) when ref in [nil, ""], do: ""
  defp ref_text(ref), do: " for #{ref}"

  defp plural(1), do: ""
  defp plural(_count), do: "s"

  defp first_present(values) do
    Enum.find_value(values, "", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_integer(value) ->
        Integer.to_string(value)

      _value ->
        nil
    end)
  end

  defp field(nil, _key), do: nil

  defp field(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key)

  defp field(_value, _key), do: nil

  defp json_list(value) when is_list(value), do: value

  defp json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      _other -> []
    end
  end

  defp json_list(_value), do: []

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp truncate(value, max) do
    value = to_string(value || "")

    if String.length(value) > max do
      String.slice(value, 0, max - 3) <> "..."
    else
      value
    end
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp iso_time(nil), do: nil
  defp iso_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso_time(value) when is_binary(value), do: value
  defp iso_time(_value), do: nil
end
