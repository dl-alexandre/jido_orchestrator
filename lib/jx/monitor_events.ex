defmodule JX.MonitorEvents do
  @moduledoc """
  Durable, deduplicated event journal for monitor scans.

  Session observations keep raw evidence. Monitor events keep the compact stream
  an orchestrator needs to answer "what changed since I last checked?"
  """

  import Ecto.Query

  alias JX.CallHandoffs
  alias JX.Delegations
  alias JX.MonitorEvents.Cursor
  alias JX.MonitorEvents.Event
  alias JX.Repo

  require Logger

  @default_consumer "orchestrator"

  @change_kinds ~w(
    session.new
    session.changed
    session.attention
    session.ready
    session.blocked
    session.awaiting_observation
    watch.completed
    watch.blocked
    ci.passed
    ci.failed
    ci.cancelled
    ci.superseded
    orchestrator.health
    call.handoff.open
    delegation.open
    delegation.review
    devide.workspace.blocked
    devide.workspace.needs_review
    devide.workspace.recovered
    external.wake
    queue.snapshot
  )

  def change_kinds, do: @change_kinds
  def default_consumer, do: @default_consumer

  def record_scan(scan) do
    with {:ok, events} <-
           scan
           |> scan_events()
           |> insert_new_events() do
      :ok = dispatch_event_signals(events)
      {:ok, events}
    end
  end

  def record_event(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:payload, %{})
      |> put_default_fingerprint()

    with {:ok, events} <- insert_new_events([attrs]) do
      :ok = dispatch_event_signals(events)
      {:ok, events}
    end
  end

  def to_signals(events) when is_list(events), do: Enum.map(events, &to_signal/1)

  def to_signal(%Event{} = event) do
    Jido.Signal.new!(event.kind, signal_data(event), signal_attrs(event))
  end

  def dispatch_event_signals(events, dispatch_config \\ nil)

  def dispatch_event_signals([], _dispatch_config), do: :ok

  def dispatch_event_signals(events, dispatch_config) when is_list(events) do
    dispatch_config = dispatch_config || monitor_event_dispatch()

    events
    |> to_signals()
    |> Enum.reduce_while(:ok, fn signal, :ok ->
      case Jido.Signal.Dispatch.dispatch(signal, dispatch_config) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          Logger.warning("monitor event signal dispatch failed: #{inspect(reason)}")
          {:halt, :ok}
      end
    end)
  end

  def list_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Event
    |> maybe_filter_since_id(Keyword.get(opts, :since_id))
    |> maybe_filter_ref(Keyword.get(opts, :ref))
    |> maybe_filter_kind(Keyword.get(opts, :kind))
    |> maybe_filter_kinds(Keyword.get(opts, :kinds))
    |> maybe_filter_severity(Keyword.get(opts, :severity))
    |> order_by([event], desc: event.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def unread_events(opts \\ []) do
    consumer = Keyword.get(opts, :consumer, @default_consumer) |> normalize_consumer()
    cursor = get_cursor(consumer)
    limit = Keyword.get(opts, :limit, 20)
    unread_total = unread_count(cursor.last_event_id)
    matching_unread_total = unread_count(cursor.last_event_id, opts)

    events =
      Event
      |> maybe_filter_since_id(cursor.last_event_id)
      |> maybe_filter_ref(Keyword.get(opts, :ref))
      |> maybe_filter_kind(Keyword.get(opts, :kind))
      |> maybe_filter_kinds(Keyword.get(opts, :kinds))
      |> maybe_filter_severity(Keyword.get(opts, :severity))
      |> order_by([event], asc: event.id)
      |> limit(^limit)
      |> Repo.all()

    {:ok,
     %{
       consumer: consumer,
       cursor: cursor_summary(cursor),
       latest_event_id: latest_event_id(),
       unread_total: unread_total,
       matching_unread_total: matching_unread_total,
       returned: length(events),
       events: events
     }}
  end

  def acknowledge(opts \\ []) do
    consumer = Keyword.get(opts, :consumer, @default_consumer) |> normalize_consumer()
    requested_id = Keyword.get(opts, :to_id)
    latest_id = latest_event_id()
    event_id = requested_id || latest_id
    now = DateTime.utc_now()
    cursor = Repo.get_by(Cursor, consumer: consumer) || %Cursor{consumer: consumer}

    cond do
      not is_integer(event_id) ->
        {:error, "event id must be an integer"}

      event_id < 0 ->
        {:error, "event id must be a non-negative integer"}

      event_id > latest_id ->
        {:error, "cannot acknowledge event #{event_id}; latest event id is #{latest_id}"}

      true ->
        last_event_id = max(cursor.last_event_id || 0, event_id)
        attrs = %{consumer: consumer, last_event_id: last_event_id, last_seen_at: now}

        with {:ok, cursor} <-
               cursor
               |> Cursor.changeset(attrs)
               |> Repo.insert_or_update() do
          {:ok, cursor_summary(cursor)}
        end
    end
  end

  def status(opts \\ []) do
    consumer = Keyword.get(opts, :consumer, @default_consumer) |> normalize_consumer()
    cursor = get_cursor(consumer)
    latest = latest_event_id()

    %{
      consumer: consumer,
      cursor: cursor_summary(cursor),
      latest_event_id: latest,
      unread_total: unread_count(cursor.last_event_id),
      caught_up: cursor.last_event_id >= latest,
      latest_event: latest_event()
    }
  end

  # Persists a batch of candidate events with deduplication semantics that
  # match the original per-row `duplicate_latest?/1` check, but in a single
  # round-trip lookup instead of N. An event is dropped iff its fingerprint
  # equals the most-recently-kept fingerprint for its (ref, kind). The fold
  # carries the latest-fingerprint map forward through the batch, so events
  # *within* the same batch are deduplicated against each other too —
  # closing the implicit gap in the previous implementation.
  #
  # Returns {:ok, inserted_events} on success.
  defp insert_new_events([]), do: {:ok, []}

  defp insert_new_events(events) do
    now = DateTime.utc_now()
    prepared = Enum.map(events, &prepare_event_attrs(&1, now))
    latest_map = fetch_latest_fingerprints_for(prepared)

    {kept_rev, _final_latest} =
      Enum.reduce(prepared, {[], latest_map}, fn attrs, {kept, latest} ->
        key = {Map.get(attrs, :ref, ""), Map.fetch!(attrs, :kind)}
        fp = Map.fetch!(attrs, :fingerprint)

        if Map.get(latest, key) == fp do
          {kept, latest}
        else
          {[attrs | kept], Map.put(latest, key, fp)}
        end
      end)

    kept = Enum.reverse(kept_rev)
    expected = length(kept)

    Repo.transaction(fn ->
      case Repo.insert_all(Event, kept, returning: true) do
        {^expected, inserted} ->
          inserted

        {n, _partial} ->
          Repo.rollback({:partial_insert, n, expected})
      end
    end)
  end

  defp prepare_event_attrs(attrs, now) do
    attrs
    |> Map.put_new(:event_id, event_id())
    |> Map.put_new(:ref, "")
    |> Map.put_new(:project, "")
    |> Map.put_new(:session_type, "")
    |> Map.put_new(:session_kind, "")
    |> Map.put_new(:control_mode, "")
    |> Map.put_new(:work_state, "")
    |> Map.put_new(:action, "")
    |> Map.put_new(:summary, "")
    |> Map.update!(:payload, &encode_payload/1)
    |> Map.put(:inserted_at, now)
    |> trim_string_fields()
  end

  @trimmed_fields ~w(event_id kind severity ref project session_type session_kind
                     control_mode work_state action summary fingerprint)a

  defp trim_string_fields(attrs) do
    Enum.reduce(@trimmed_fields, attrs, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        value when is_binary(value) -> Map.put(acc, key, String.trim(value))
        _ -> acc
      end
    end)
  end

  # Single query returning {ref, kind} => latest fingerprint for every
  # (ref, kind) pair that has any existing row whose ref and kind both
  # appear in the candidate batch. Uses the (ref, kind, id) composite
  # index added in migration 20260515000000.
  #
  # The WHERE filter is `ref IN refs AND kind IN kinds` rather than a
  # tuple-IN, so it may over-select pairs that exist in the table but
  # weren't in this batch. That's correct: the fold only looks up keys
  # it cares about, and the over-fetch is bounded by U_ref × U_kind
  # (typically tens).
  defp fetch_latest_fingerprints_for([]), do: %{}

  defp fetch_latest_fingerprints_for(prepared) do
    refs = prepared |> Enum.map(&Map.get(&1, :ref, "")) |> Enum.uniq()
    kinds = prepared |> Enum.map(&Map.fetch!(&1, :kind)) |> Enum.uniq()

    latest_ids =
      from(e in Event,
        where: e.ref in ^refs and e.kind in ^kinds,
        group_by: [e.ref, e.kind],
        select: %{ref: e.ref, kind: e.kind, max_id: max(e.id)}
      )

    from(e in Event,
      join: l in subquery(latest_ids),
      on: e.id == l.max_id,
      select: {e.ref, e.kind, e.fingerprint}
    )
    |> Repo.all()
    |> Map.new(fn {ref, kind, fp} -> {{ref, kind}, fp} end)
  end

  defp put_default_fingerprint(attrs) do
    Map.put_new_lazy(attrs, :fingerprint, fn ->
      fingerprint(%{
        kind: Map.get(attrs, :kind, ""),
        ref: Map.get(attrs, :ref, ""),
        project: Map.get(attrs, :project, ""),
        action: Map.get(attrs, :action, ""),
        summary: Map.get(attrs, :summary, ""),
        payload: Map.get(attrs, :payload, %{})
      })
    end)
  end

  defp get_cursor(consumer) do
    Repo.get_by(Cursor, consumer: consumer) ||
      %Cursor{
        consumer: consumer,
        last_event_id: 0,
        last_seen_at: nil
      }
  end

  defp cursor_summary(%Cursor{} = cursor) do
    %{
      consumer: cursor.consumer,
      source: if(cursor.id, do: "stored", else: "default"),
      last_event_id: cursor.last_event_id || 0,
      last_seen_at: cursor.last_seen_at,
      updated_at: cursor.updated_at
    }
  end

  def latest_event_id do
    Event
    |> select([event], max(event.id))
    |> Repo.one()
    |> case do
      nil -> 0
      id -> id
    end
  end

  defp latest_event do
    Event
    |> order_by([event], desc: event.id)
    |> limit(1)
    |> Repo.one()
  end

  defp unread_count(last_event_id) do
    Event
    |> where([event], event.id > ^last_event_id)
    |> Repo.aggregate(:count, :id)
  end

  defp unread_count(last_event_id, opts) do
    Event
    |> maybe_filter_since_id(last_event_id)
    |> maybe_filter_ref(Keyword.get(opts, :ref))
    |> maybe_filter_kind(Keyword.get(opts, :kind))
    |> maybe_filter_kinds(Keyword.get(opts, :kinds))
    |> maybe_filter_severity(Keyword.get(opts, :severity))
    |> Repo.aggregate(:count, :id)
  end

  defp normalize_consumer(nil), do: @default_consumer

  defp normalize_consumer(consumer) when is_binary(consumer) do
    case String.trim(consumer) do
      "" -> @default_consumer
      normalized -> normalized
    end
  end

  defp normalize_consumer(consumer), do: consumer |> to_string() |> normalize_consumer()

  defp monitor_event_dispatch do
    Application.get_env(:jx, :monitor_event_dispatch, {:noop, []})
  end

  defp signal_attrs(%Event{} = event) do
    attrs = [
      id: event.event_id,
      source: "/jx/monitor_events",
      time: DateTime.to_iso8601(event.inserted_at)
    ]

    if present?(event.ref) do
      Keyword.put(attrs, :subject, event.ref)
    else
      attrs
    end
  end

  defp signal_data(%Event{} = event) do
    %{
      event_id: event.event_id,
      kind: event.kind,
      severity: event.severity,
      ref: event.ref,
      project: event.project,
      session_type: event.session_type,
      session_kind: event.session_kind,
      control_mode: event.control_mode,
      work_state: event.work_state,
      action: event.action,
      summary: event.summary,
      fingerprint: event.fingerprint,
      payload: decode_payload(event.payload)
    }
  end

  defp decode_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{"raw" => payload}
    end
  end

  defp decode_payload(_payload), do: %{}

  defp scan_events(scan) do
    profiles = Map.get(scan, :profiles, [])
    queues = Map.get(scan, :queues, [])
    watch_updates = Map.get(scan, :watch_updates, [])
    ci_watch_updates = Map.get(scan, :ci_watch_updates, [])
    daemon_health_alerts = Map.get(scan, :daemon_health_alerts, [])
    call_handoffs = Map.get(scan, :call_handoffs, [])
    delegations = Map.get(scan, :delegations, [])
    delegation_reviews = Map.get(scan, :delegation_reviews, [])

    [queue_event(queues) | Enum.flat_map(profiles, &profile_events/1)]
    |> Kernel.++(Enum.flat_map(watch_updates, &watch_events/1))
    |> Kernel.++(Enum.flat_map(ci_watch_updates, &ci_events/1))
    |> Kernel.++(Enum.map(daemon_health_alerts, &daemon_health_event/1))
    |> Kernel.++(Enum.map(call_handoffs, &call_handoff_event/1))
    |> Kernel.++(Enum.map(delegations, &delegation_event/1))
    |> Kernel.++(Enum.map(delegation_reviews, &delegation_review_event/1))
    |> Enum.reject(&is_nil/1)
  end

  defp queue_event([]), do: nil

  defp queue_event(queues) do
    totals = Enum.map(queues, &%{action: &1.action, total: &1.total})
    fingerprint = fingerprint(%{totals: totals})

    %{
      kind: "queue.snapshot",
      severity: "info",
      summary: queue_summary(queues),
      action: "monitor",
      fingerprint: fingerprint,
      payload: %{queues: totals}
    }
  end

  defp profile_events(profile) do
    []
    |> maybe_event(session_changed_event(profile))
    |> maybe_event(state_event(profile))
  end

  defp watch_events(%{changed?: true, status: "completed"} = update) do
    [watch_event(update, "watch.completed", "notice", "watch completed")]
  end

  defp watch_events(%{changed?: true, status: "blocked"} = update) do
    [watch_event(update, "watch.blocked", "warning", "watch blocker matched")]
  end

  defp watch_events(_update), do: []

  defp ci_events(%{changed?: true, status: "passed"} = update) do
    [ci_event(update, "ci.passed", "notice", "CI watch passed")]
  end

  defp ci_events(%{changed?: true, status: "failed"} = update) do
    [ci_event(update, "ci.failed", "warning", "CI watch failed")]
  end

  defp ci_events(%{changed?: true, status: "cancelled"} = update) do
    [ci_event(update, "ci.cancelled", "warning", "CI watch cancelled")]
  end

  defp ci_events(%{changed?: true, status: "superseded"} = update) do
    [ci_event(update, "ci.superseded", "notice", "CI watch superseded by newer head")]
  end

  defp ci_events(_update), do: []

  defp daemon_health_event(alert) do
    %{
      kind: Map.get(alert, :kind, "orchestrator.health"),
      severity: Map.get(alert, :severity, "warning"),
      ref: Map.get(alert, :daemon_key, ""),
      project: "",
      session_type: "",
      session_kind: "",
      control_mode: "",
      work_state: Map.get(alert, :status, ""),
      action: "orchestrator-health",
      summary: Map.get(alert, :summary, "orchestrator health alert"),
      fingerprint: fingerprint(Map.get(alert, :fingerprint, alert)),
      payload: alert
    }
  end

  defp call_handoff_event(handoff) do
    summary = CallHandoffs.handoff_summary(handoff)

    %{
      kind: "call.handoff.open",
      severity: "notice",
      ref: handoff.handoff_id,
      project: handoff.project || "",
      session_type: "",
      session_kind: "",
      control_mode: "",
      work_state: "",
      action: "call-handoff",
      summary: call_handoff_summary(summary),
      fingerprint:
        fingerprint(%{
          handoff_id: handoff.handoff_id,
          status: handoff.status,
          title: handoff.title,
          summary: handoff.summary,
          decisions: handoff.decisions,
          follow_ups: handoff.follow_ups
        }),
      payload: summary
    }
  end

  defp delegation_event(delegation) do
    summary = Delegations.delegation_summary(delegation)

    %{
      kind: "delegation.open",
      severity: delegation_severity(summary),
      ref: delegation.ref || "",
      project: delegation.project || "",
      session_type: "",
      session_kind: "",
      control_mode: "",
      work_state: delegation.status || "",
      action: "delegate",
      summary: delegation_summary(summary),
      fingerprint:
        fingerprint(%{
          delegation_id: delegation.delegation_id,
          status: delegation.status,
          title: delegation.title,
          brief: delegation.brief,
          lint_warnings: delegation.lint_warnings,
          evidence: delegation.evidence,
          residual_risks: delegation.residual_risks,
          worker_summary: delegation.worker_summary
        }),
      payload: summary
    }
  end

  defp delegation_severity(%{status: "blocked"}), do: "warning"
  defp delegation_severity(%{lint_warnings: [_warning | _rest]}), do: "warning"
  defp delegation_severity(_summary), do: "notice"

  defp delegation_review_event(review) do
    %{
      kind: "delegation.review",
      severity: delegation_review_severity(review),
      ref: Map.get(review, :ref, ""),
      project: Map.get(review, :project, ""),
      session_type: "",
      session_kind: "",
      control_mode: "",
      work_state: "completed",
      action: "delegate-review",
      summary: delegation_review_summary(review),
      fingerprint:
        fingerprint(%{
          delegation_id: Map.get(review, :delegation_id),
          decision: Map.get(review, :decision),
          summary: Map.get(review, :summary),
          warnings: Map.get(review, :warnings, []),
          foreground: Map.get(review, :foreground, %{}),
          evidence: Map.get(review, :evidence, %{}),
          ownership: Map.get(review, :ownership, %{})
        }),
      payload: review
    }
  end

  defp delegation_review_severity(%{decision: decision}) when decision in ["reject", "revise"],
    do: "warning"

  defp delegation_review_severity(%{decision: "hold"}), do: "notice"
  defp delegation_review_severity(_review), do: "notice"

  defp ci_event(update, kind, severity, reason) do
    watch = update.watch

    %{
      kind: kind,
      severity: severity,
      ref: watch.ref || "",
      project: watch.project || "",
      session_type: "",
      session_kind: "",
      control_mode: "",
      work_state: "",
      action: "ci-watch",
      summary: ci_summary(update, reason),
      fingerprint:
        fingerprint(%{
          watch_id: watch.watch_id,
          status: watch.status,
          last_overall: watch.last_overall,
          last_summary: watch.last_summary,
          head_sha: Map.get(watch, :head_sha),
          last_head_sha: Map.get(watch, :last_head_sha)
        }),
      payload: ci_payload(update, reason)
    }
  end

  defp watch_event(update, kind, severity, reason) do
    watch = update.watch
    profile = update.profile
    payload = watch_payload(update, reason)

    %{
      kind: kind,
      severity: severity,
      ref: watch.ref,
      project: watch.project || get_in(profile, [:session, :project]) || "",
      session_type: watch.session_type || get_in(profile, [:session, :type]) || "",
      session_kind: watch.session_kind || get_in(profile, [:session, :kind]) || "",
      control_mode: get_in(profile, [:session, :control_mode]) || "",
      work_state: get_in(profile, [:actual, :work_state]) || "",
      action: "watch",
      summary: watch_summary(update, reason),
      fingerprint:
        fingerprint(%{
          watch_id: watch.watch_id,
          status: watch.status,
          result_summary: watch.result_summary
        }),
      payload: payload
    }
  end

  defp session_changed_event(profile) do
    change = get_in(profile, [:actual, :change, :change])

    case change do
      "new" -> profile_event(profile, "session.new", "info", "new session observed")
      "changed" -> profile_event(profile, "session.changed", "notice", "session changed")
      _other -> nil
    end
  end

  defp state_event(profile) do
    state = get_in(profile, [:comparison, :state])

    case state do
      "ready-to-send" ->
        profile_event(profile, "session.ready", "notice", "session has a chambered prompt ready")

      "blocked" ->
        profile_event(profile, "session.blocked", "warning", "session is blocked")

      "awaiting-observation" ->
        profile_event(
          profile,
          "session.awaiting_observation",
          "info",
          "directive sent; observe before sending again"
        )

      "needs-attention" ->
        profile_event(profile, "session.attention", "warning", "session needs attention")

      _state ->
        nil
    end
  end

  defp profile_event(profile, kind, severity, reason) do
    payload = profile_payload(profile, reason)
    fingerprint = fingerprint(profile_fingerprint_payload(profile, reason))

    %{
      kind: kind,
      severity: severity,
      ref: profile.ref,
      project: get_in(profile, [:session, :project]) || "",
      session_type: get_in(profile, [:session, :type]) || "",
      session_kind: get_in(profile, [:session, :kind]) || "",
      control_mode: get_in(profile, [:session, :control_mode]) || "",
      work_state: get_in(profile, [:actual, :work_state]) || "",
      action: get_in(profile, [:actual, :next_action, :action]) || "",
      summary: profile_summary(profile, reason),
      fingerprint: fingerprint,
      payload: payload
    }
  end

  defp profile_fingerprint_payload(profile, reason) do
    %{
      reason: reason,
      ref: profile.ref,
      comparison_state: get_in(profile, [:comparison, :state]),
      next_step: profile.next_step,
      prompt_status: get_in(profile, [:planned, :prompt_status]),
      next_prompt_status: get_in(profile, [:next_prompt, :status]),
      next_prompt_text: get_in(profile, [:next_prompt, :text]),
      work_state: get_in(profile, [:actual, :work_state]),
      capture_status: get_in(profile, [:actual, :capture_status]),
      summary: get_in(profile, [:actual, :summary]),
      task: get_in(profile, [:actual, :task]),
      action: get_in(profile, [:actual, :next_action, :action]),
      action_reason: get_in(profile, [:actual, :next_action, :reason]),
      directive_state: get_in(profile, [:actual, :directive_state]),
      directive_id: get_in(profile, [:actual, :last_directive, :directive_id]),
      repo: %{
        branch: get_in(profile, [:actual, :repo, :branch]),
        dirty: get_in(profile, [:actual, :repo, :dirty]),
        ahead: get_in(profile, [:actual, :repo, :ahead]),
        behind: get_in(profile, [:actual, :repo, :behind]),
        blockers: get_in(profile, [:actual, :repo, :blockers]),
        risks: get_in(profile, [:actual, :repo, :risks])
      },
      changed_fields: get_in(profile, [:actual, :change, :changed_fields])
    }
  end

  defp profile_payload(profile, reason) do
    %{
      reason: reason,
      ref: profile.ref,
      session: profile.session,
      planned: profile.planned,
      comparison: profile.comparison,
      next_step: profile.next_step,
      next_prompt: profile.next_prompt,
      actual: %{
        work_state: get_in(profile, [:actual, :work_state]),
        capture_status: get_in(profile, [:actual, :capture_status]),
        summary: get_in(profile, [:actual, :summary]),
        task: get_in(profile, [:actual, :task]),
        next_action: get_in(profile, [:actual, :next_action]),
        directive_state: get_in(profile, [:actual, :directive_state]),
        last_directive: get_in(profile, [:actual, :last_directive]),
        change: get_in(profile, [:actual, :change]),
        repo: get_in(profile, [:actual, :repo])
      }
    }
  end

  defp watch_payload(update, reason) do
    watch = update.watch

    %{
      reason: reason,
      watch: %{
        watch_id: watch.watch_id,
        ref: watch.ref,
        status: watch.status,
        previous_status: update.previous_status,
        mode: watch.mode,
        goal: watch.goal,
        success_pattern: watch.success_pattern,
        blocker_pattern: watch.blocker_pattern,
        result_summary: watch.result_summary,
        last_summary: watch.last_summary,
        completed_at: watch.completed_at,
        head_sha: Map.get(watch, :head_sha),
        last_head_sha: Map.get(watch, :last_head_sha),
        last_head_checked_at: Map.get(watch, :last_head_checked_at)
      },
      profile: %{
        session: update.profile.session,
        comparison: update.profile.comparison,
        actual: %{
          work_state: get_in(update.profile, [:actual, :work_state]),
          capture_status: get_in(update.profile, [:actual, :capture_status]),
          summary: get_in(update.profile, [:actual, :summary]),
          task: get_in(update.profile, [:actual, :task])
        }
      }
    }
  end

  defp ci_payload(update, reason) do
    watch = update.watch

    %{
      reason: reason,
      watch: %{
        watch_id: watch.watch_id,
        repo: watch.repo,
        pr_number: watch.pr_number,
        ref: watch.ref,
        project: watch.project,
        status: watch.status,
        previous_status: update.previous_status,
        mode: watch.mode,
        goal: watch.goal,
        last_overall: watch.last_overall,
        last_summary: watch.last_summary,
        head_sha: Map.get(watch, :head_sha),
        last_head_sha: Map.get(watch, :last_head_sha),
        last_head_checked_at: Map.get(watch, :last_head_checked_at),
        last_checked_at: watch.last_checked_at,
        completed_at: watch.completed_at
      },
      profile_action: Map.get(update, :profile_action),
      digest: compact_digest(update.digest)
    }
  end

  defp maybe_event(events, nil), do: events
  defp maybe_event(events, event), do: [event | events]

  defp profile_summary(profile, reason) do
    [
      reason,
      profile.ref,
      get_in(profile, [:session, :project]),
      get_in(profile, [:comparison, :state]),
      get_in(profile, [:next_step]),
      first_present([
        get_in(profile, [:actual, :summary]),
        get_in(profile, [:actual, :task]),
        get_in(profile, [:comparison, :actual_summary])
      ])
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
    |> truncate(240)
  end

  defp watch_summary(update, reason) do
    watch = update.watch

    [
      reason,
      watch.watch_id,
      watch.ref,
      watch.goal,
      watch.result_summary
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
    |> truncate(240)
  end

  defp ci_summary(update, reason) do
    watch = update.watch

    [
      reason,
      watch.watch_id,
      "#{watch.repo}##{watch.pr_number}",
      watch.ref,
      watch.goal,
      watch.last_summary
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
    |> truncate(240)
  end

  defp call_handoff_summary(handoff) do
    [
      "call handoff open",
      handoff.handoff_id,
      handoff.project,
      handoff.ref,
      first_present([handoff.title, handoff.summary, handoff.operator_input])
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
    |> truncate(240)
  end

  defp delegation_summary(delegation) do
    [
      "delegation #{delegation.status}",
      delegation.delegation_id,
      delegation.project,
      delegation.ref,
      first_present([delegation.worker_summary, delegation.title, delegation.brief])
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
    |> truncate(240)
  end

  defp delegation_review_summary(review) do
    [
      "delegation review #{Map.get(review, :decision, "")}",
      Map.get(review, :delegation_id, ""),
      Map.get(review, :project, ""),
      Map.get(review, :ref, ""),
      first_present([Map.get(review, :summary), Map.get(review, :title)])
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
    |> truncate(240)
  end

  defp queue_summary(queues) do
    queues
    |> Enum.map(&"#{&1.action}:#{&1.total}")
    |> Enum.join(" ")
    |> truncate(240)
  end

  defp fingerprint(payload) do
    payload
    |> :erlang.term_to_binary()
    |> then(fn binary -> :crypto.hash(:sha256, binary) end)
    |> Base.encode16(case: :lower)
  end

  defp encode_payload(payload) when is_binary(payload), do: payload
  defp encode_payload(payload), do: Jason.encode!(payload)

  defp compact_digest(nil), do: nil

  defp compact_digest(digest) do
    %{
      repo: Map.get(digest, :repo),
      pr: Map.get(digest, :pr),
      overall: Map.get(digest, :overall),
      totals: Map.get(digest, :totals),
      blockers: Map.get(digest, :blockers),
      head_sha: Map.get(digest, :head_sha),
      head_ref_name: Map.get(digest, :head_ref_name),
      url: Map.get(digest, :url)
    }
  end

  defp maybe_filter_since_id(query, nil), do: query

  defp maybe_filter_since_id(query, since_id) when is_integer(since_id) do
    where(query, [event], event.id > ^since_id)
  end

  defp maybe_filter_ref(query, nil), do: query
  defp maybe_filter_ref(query, ref), do: where(query, [event], event.ref == ^ref)

  defp maybe_filter_kind(query, nil), do: query
  defp maybe_filter_kind(query, kind), do: where(query, [event], event.kind == ^kind)

  defp maybe_filter_kinds(query, nil), do: query
  defp maybe_filter_kinds(query, []), do: where(query, [_event], false)
  defp maybe_filter_kinds(query, kinds), do: where(query, [event], event.kind in ^kinds)

  defp maybe_filter_severity(query, nil), do: query

  defp maybe_filter_severity(query, severity),
    do: where(query, [event], event.severity == ^severity)

  defp first_present(values) do
    Enum.find_value(values, "", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end)
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp present?(value), do: not blank?(value)

  defp truncate(value, max) when byte_size(value) <= max, do: value
  defp truncate(value, max), do: binary_part(value, 0, max) <> "..."

  defp event_id do
    random =
      5
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    "evt-" <> random
  end
end
