defmodule JX.Delegations do
  @moduledoc """
  Durable delegation queue for bounded worker-agent problem packets.
  """

  import Ecto.Query

  alias JX.DelegationPreflight
  alias JX.Delegations.Delegation
  alias JX.Repo

  @delegation_prefix "dlg-"
  @default_timing_limit 500
  @stale_review_after_seconds 30 * 60
  @long_running_floor_seconds 60 * 60

  def statuses, do: Delegation.statuses()
  def agent_kinds, do: Delegation.agent_kinds()
  def integration_statuses, do: Delegation.integration_statuses()
  def review_decisions, do: ~w(accept revise reject hold)

  def create(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:delegation_id, delegation_id())
      |> Map.put_new(:status, "queued")
      |> Map.put_new(:priority, 0)
      |> Map.put_new(:source, "foreground")
      |> Map.put_new(:owner, "")
      |> Map.put_new(:agent_kind, "worker")
      |> Map.put_new(:integration_status, "pending")
      |> encode_json_field(:context, [])
      |> encode_json_field(:constraints, [])
      |> encode_json_field(:acceptance, [])
      |> encode_json_field(:verification, [])
      |> encode_json_field(:write_paths, [])
      |> encode_json_field(:forbidden_paths, [])
      |> encode_json_field(:evidence, [])
      |> encode_json_field(:residual_risks, [])
      |> encode_json_field(:artifacts, [])
      |> encode_json_field(:payload, %{})

    attrs =
      attrs
      |> Map.put_new(
        :lint_warnings,
        DelegationPreflight.lint_warnings(attrs, open_delegations())
      )
      |> encode_json_field(:lint_warnings, [])

    %Delegation{}
    |> Delegation.changeset(attrs)
    |> Repo.insert()
  end

  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Delegation
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_project(Keyword.get(opts, :project))
    |> maybe_filter_ref(Keyword.get(opts, :ref))
    |> maybe_filter_owner(Keyword.get(opts, :owner))
    |> order_by([delegation], desc: delegation.priority, desc: delegation.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def get(delegation_id), do: Repo.get_by(Delegation, delegation_id: delegation_id)

  def start(delegation_id, attrs \\ []) do
    case get(delegation_id) do
      nil ->
        {:error, :delegation_not_found}

      %Delegation{} = delegation ->
        with {:ok, report} <- DelegationPreflight.start_gate(delegation, open_delegations()) do
          attrs =
            attrs
            |> Map.new()
            |> Map.take([:owner, :worker_summary])
            |> Map.put(:status, "running")
            |> Map.put(:claimed_at, DateTime.utc_now())
            |> Map.put(:lint_warnings, report.warnings)
            |> encode_json_field(:lint_warnings, [])

          update_delegation(delegation_id, attrs)
        end
    end
  end

  def add_evidence(delegation_id, attrs) do
    case get(delegation_id) do
      nil ->
        {:error, :delegation_not_found}

      %Delegation{} = delegation ->
        with {:ok, entry} <- evidence_entry(attrs) do
          update_delegation(
            delegation_id,
            %{
              evidence: append_json(delegation.evidence, [entry]),
              artifacts: merge_json_lists(delegation.artifacts, Map.get(entry, "artifacts", [])),
              residual_risks:
                merge_json_lists(delegation.residual_risks, Map.get(entry, "risks", []))
            }
          )
        end
    end
  end

  def complete(delegation_id, attrs \\ []) do
    case get(delegation_id) do
      nil ->
        {:error, :delegation_not_found}

      %Delegation{} = delegation ->
        with {:ok, evidence_entries} <- evidence_entries(Map.new(attrs)) do
          attrs = Map.new(attrs)
          evidence_artifacts = Enum.flat_map(evidence_entries, &Map.get(&1, "artifacts", []))
          evidence_risks = Enum.flat_map(evidence_entries, &Map.get(&1, "risks", []))

          update_attrs =
            attrs
            |> Map.take([:worker_summary, :payload])
            |> Map.put(
              :verification,
              Map.get(attrs, :verification, decode_json_list(delegation.verification))
            )
            |> Map.put(
              :artifacts,
              merge_lists(
                decode_json_list(delegation.artifacts) ++ Map.get(attrs, :artifacts, []),
                evidence_artifacts
              )
            )
            |> encode_json_field(:verification, [])
            |> encode_json_field(:artifacts, [])
            |> maybe_encode_json_field(:payload)
            |> Map.put(:evidence, append_json(delegation.evidence, evidence_entries))
            |> Map.put(
              :residual_risks,
              merge_json_lists(
                delegation.residual_risks,
                json_list(Map.get(attrs, :residual_risks, [])) ++ evidence_risks
              )
            )
            |> Map.put(:status, "completed")
            |> Map.put(:completed_at, DateTime.utc_now())

          update_delegation(delegation_id, update_attrs)
        end
    end
  end

  def block(delegation_id, summary) do
    update_delegation(delegation_id, %{status: "blocked", worker_summary: summary})
  end

  def fail(delegation_id, summary) do
    update_delegation(delegation_id, %{
      status: "failed",
      worker_summary: summary,
      completed_at: DateTime.utc_now()
    })
  end

  def cancel(delegation_id, summary \\ "") do
    update_delegation(delegation_id, %{
      status: "cancelled",
      worker_summary: summary,
      completed_at: DateTime.utc_now()
    })
  end

  def brief_packet(delegation_id) do
    case get(delegation_id) do
      nil -> {:error, :delegation_not_found}
      %Delegation{} = delegation -> {:ok, render_packet(delegation)}
    end
  end

  def preflight(delegation_id) do
    case get(delegation_id) do
      nil ->
        {:error, :delegation_not_found}

      %Delegation{} = delegation ->
        {:ok, DelegationPreflight.lint(delegation, open_delegations())}
    end
  end

  def review(delegation_id) do
    case get(delegation_id) do
      nil -> {:error, :delegation_not_found}
      %Delegation{} = delegation -> {:ok, review_card(delegation)}
    end
  end

  def list_reviews(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    opts
    |> review_delegations_query()
    |> order_by([delegation], desc: delegation.priority, desc: delegation.updated_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&review_card/1)
    |> maybe_filter_review_decision(Keyword.get(opts, :decision))
  end

  def timing_summary(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, @default_timing_limit)

    completed = completed_delegations(opts, limit)
    active = active_delegations(opts, limit)
    pending_reviews = pending_review_delegations(opts, limit)

    samples = Enum.map(completed, &delegation_timing(&1, now))
    global = timing_stats(samples)
    active_summary = active_timing_summary(active, samples, now, limit)
    pending_review_summary = pending_review_timing_summary(pending_reviews, now, limit)

    %{
      generated_at: now,
      samples_total: length(samples),
      global: global,
      by_agent_kind: grouped_timing_stats(samples, :agent_kind),
      by_project: grouped_timing_stats(samples, :project),
      active: active_summary,
      pending_reviews: pending_review_summary,
      assignment:
        assignment_recommendation(active_summary, pending_review_summary,
          target_parallel: Keyword.get(opts, :target_parallel, 3)
        ),
      latest_samples: Enum.take(samples, Keyword.get(opts, :latest, 10)),
      thresholds: %{
        stale_review_after_seconds: @stale_review_after_seconds,
        long_running_floor_seconds: @long_running_floor_seconds
      }
    }
  end

  def decide_review(delegation_id, decision, attrs \\ []) do
    with {:ok, integration_status} <- integration_status_for_decision(decision) do
      case get(delegation_id) do
        nil ->
          {:error, :delegation_not_found}

        %Delegation{status: status} when status != "completed" ->
          {:error, {:delegation_not_completed, status}}

        %Delegation{} = delegation ->
          review = review_card(delegation)

          update_delegation(delegation_id, %{
            integration_status: integration_status,
            integration_summary: review_summary_text(attrs, review),
            reviewed_by: clean(Map.get(Map.new(attrs), :reviewer, "")),
            reviewed_at: DateTime.utc_now()
          })
      end
    end
  end

  def summary(opts \\ []) do
    delegations = list(Keyword.put_new(opts, :limit, 500))

    %{
      total: length(delegations),
      open_total: Enum.count(delegations, &(&1.status in ["queued", "running", "blocked"])),
      by_status: count_by(delegations, & &1.status),
      by_project: count_by(delegations, & &1.project),
      latest:
        delegations
        |> Enum.take(Keyword.get(opts, :latest, 5))
        |> Enum.map(&delegation_summary/1)
    }
  end

  def delegation_summary(%Delegation{} = delegation) do
    %{
      delegation_id: delegation.delegation_id,
      status: delegation.status,
      priority: delegation.priority,
      project: delegation.project,
      ref: delegation.ref,
      source: delegation.source,
      owner: delegation.owner,
      agent_kind: delegation.agent_kind,
      title: delegation.title,
      brief: delegation.brief,
      context: decode_json_list(delegation.context),
      constraints: decode_json_list(delegation.constraints),
      acceptance: decode_json_list(delegation.acceptance),
      verification: decode_json_list(delegation.verification),
      write_paths: decode_json_list(delegation.write_paths),
      forbidden_paths: decode_json_list(delegation.forbidden_paths),
      lint_warnings: decode_json_list(delegation.lint_warnings),
      evidence: decode_json_list(delegation.evidence),
      evidence_count: length(decode_json_list(delegation.evidence)),
      latest_evidence: latest_evidence(delegation.evidence),
      residual_risks: decode_json_list(delegation.residual_risks),
      review: review_card(delegation),
      timing: delegation_timing(delegation, DateTime.utc_now()),
      integration_status: delegation.integration_status,
      integration_summary: delegation.integration_summary,
      reviewed_by: delegation.reviewed_by,
      reviewed_at: delegation.reviewed_at,
      worker_summary: delegation.worker_summary,
      artifacts: decode_json_list(delegation.artifacts),
      claimed_at: delegation.claimed_at,
      completed_at: delegation.completed_at,
      updated_at: delegation.updated_at,
      inserted_at: delegation.inserted_at
    }
  end

  defp update_delegation(delegation_id, attrs) do
    case get(delegation_id) do
      nil ->
        {:error, :delegation_not_found}

      delegation ->
        delegation
        |> Delegation.changeset(attrs)
        |> Repo.update()
    end
  end

  defp render_packet(%Delegation{} = delegation) do
    sections = [
      {"Delegation", delegation.delegation_id},
      {"Title", delegation.title},
      {"Project", delegation.project},
      {"Ref", delegation.ref},
      {"Status", delegation.status},
      {"Owner", delegation.owner},
      {"Agent Kind", delegation.agent_kind},
      {"Brief", delegation.brief},
      {"Context", decode_json_list(delegation.context)},
      {"Constraints", decode_json_list(delegation.constraints)},
      {"Acceptance", decode_json_list(delegation.acceptance)},
      {"Verification", decode_json_list(delegation.verification)},
      {"Write Paths", decode_json_list(delegation.write_paths)},
      {"Forbidden Paths", decode_json_list(delegation.forbidden_paths)},
      {"Preflight Warnings", decode_json_list(delegation.lint_warnings)},
      {"Evidence", render_evidence_list(decode_json_list(delegation.evidence))},
      {"Residual Risks", decode_json_list(delegation.residual_risks)}
    ]

    sections
    |> Enum.reject(fn {_label, value} -> blank_value?(value) end)
    |> Enum.map_join("\n\n", &render_section/1)
  end

  defp render_section({label, values}) when is_list(values) do
    body =
      values
      |> Enum.reject(&blank?/1)
      |> Enum.map_join("\n", &"- #{&1}")

    "#{label}:\n#{body}"
  end

  defp render_section({label, value}), do: "#{label}: #{value}"

  defp review_card(%Delegation{} = delegation) do
    evidence = decode_json_list(delegation.evidence)
    artifacts = decode_json_list(delegation.artifacts)
    write_paths = decode_json_list(delegation.write_paths)
    forbidden_paths = decode_json_list(delegation.forbidden_paths)
    risks = decode_json_list(delegation.residual_risks)
    lint_warnings = decode_json_list(delegation.lint_warnings)
    failed_evidence = Enum.filter(evidence, &(Map.get(&1, "status") == "failed"))
    outside_write_paths = outside_write_paths(artifacts, write_paths)
    forbidden_touches = forbidden_touches(artifacts, forbidden_paths)

    warnings =
      review_warnings(delegation, evidence, risks, outside_write_paths, forbidden_touches)

    decision =
      review_decision(
        delegation,
        failed_evidence,
        forbidden_touches,
        outside_write_paths,
        warnings
      )

    %{
      delegation_id: delegation.delegation_id,
      status: delegation.status,
      project: delegation.project,
      ref: delegation.ref,
      title: delegation.title,
      decision: decision,
      summary: review_summary(decision, warnings),
      foreground: %{
        status: delegation.integration_status,
        summary: delegation.integration_summary,
        reviewed_by: delegation.reviewed_by,
        reviewed_at: delegation.reviewed_at
      },
      warnings: warnings,
      evidence: %{
        total: length(evidence),
        passed: Enum.count(evidence, &(Map.get(&1, "status") == "passed")),
        failed: length(failed_evidence),
        latest: List.last(evidence)
      },
      ownership: %{
        write_paths: write_paths,
        forbidden_paths: forbidden_paths,
        artifacts: artifacts,
        outside_write_paths: outside_write_paths,
        forbidden_touches: forbidden_touches
      },
      residual_risks: risks,
      lint_warnings: lint_warnings
    }
  end

  defp review_warnings(delegation, evidence, risks, outside_write_paths, forbidden_touches) do
    []
    |> warn_if(delegation.status != "completed", "delegation is not completed")
    |> warn_if(blank?(delegation.worker_summary), "worker summary is missing")
    |> warn_if(evidence == [], "no structured evidence recorded")
    |> warn_if(
      Enum.any?(evidence, &(Map.get(&1, "status") == "failed")),
      "one or more evidence commands failed"
    )
    |> warn_if(risks != [], "residual risks need foreground review")
    |> warn_if(
      outside_write_paths != [],
      "artifacts include paths outside declared write ownership"
    )
    |> warn_if(forbidden_touches != [], "artifacts include forbidden paths")
  end

  defp warn_if(warnings, true, warning), do: warnings ++ [warning]
  defp warn_if(warnings, false, _warning), do: warnings

  defp integration_status_for_decision("accept"), do: {:ok, "accepted"}
  defp integration_status_for_decision("revise"), do: {:ok, "revision_requested"}
  defp integration_status_for_decision("reject"), do: {:ok, "rejected"}
  defp integration_status_for_decision("hold"), do: {:ok, "held"}

  defp integration_status_for_decision(decision),
    do: {:error, {:invalid_review_decision, decision}}

  defp review_summary_text(attrs, review) do
    attrs = Map.new(attrs)

    case clean(Map.get(attrs, :summary, "")) do
      "" -> review.summary
      summary -> summary
    end
  end

  defp maybe_filter_integration_status(query, status) when status in [nil, "", "all"], do: query

  defp maybe_filter_integration_status(query, status),
    do: where(query, [delegation], delegation.integration_status == ^status)

  defp maybe_filter_review_decision(cards, nil), do: cards
  defp maybe_filter_review_decision(cards, ""), do: cards

  defp maybe_filter_review_decision(cards, decision) do
    Enum.filter(cards, &(&1.decision == decision))
  end

  defp review_delegations_query(opts) do
    Delegation
    |> maybe_filter_status("completed")
    |> maybe_filter_project(Keyword.get(opts, :project))
    |> maybe_filter_ref(Keyword.get(opts, :ref))
    |> maybe_filter_agent_kind(Keyword.get(opts, :agent_kind))
    |> maybe_filter_integration_status(Keyword.get(opts, :integration_status, "pending"))
  end

  defp completed_delegations(opts, limit) do
    Delegation
    |> maybe_filter_status("completed")
    |> maybe_filter_project(Keyword.get(opts, :project))
    |> maybe_filter_ref(Keyword.get(opts, :ref))
    |> maybe_filter_agent_kind(Keyword.get(opts, :agent_kind))
    |> order_by([delegation], desc: delegation.completed_at, desc: delegation.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp active_delegations(opts, limit) do
    statuses = ~w(queued running blocked)

    Delegation
    |> where([delegation], delegation.status in ^statuses)
    |> maybe_filter_project(Keyword.get(opts, :project))
    |> maybe_filter_ref(Keyword.get(opts, :ref))
    |> maybe_filter_agent_kind(Keyword.get(opts, :agent_kind))
    |> order_by([delegation], desc: delegation.priority, desc: delegation.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp pending_review_delegations(opts, limit) do
    opts
    |> Keyword.put(:integration_status, "pending")
    |> review_delegations_query()
    |> order_by([delegation], desc: delegation.completed_at, desc: delegation.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp delegation_timing(%Delegation{} = delegation, now) do
    claimed_at = delegation.claimed_at
    completed_at = delegation.completed_at
    inserted_at = delegation.inserted_at
    updated_at = delegation.updated_at
    ended_at = completed_at || now

    %{
      delegation_id: delegation.delegation_id,
      status: delegation.status,
      project: delegation.project,
      ref: delegation.ref,
      agent_kind: delegation.agent_kind,
      priority: delegation.priority,
      title: delegation.title,
      queued_seconds: duration_seconds(inserted_at, claimed_at || ended_at),
      runtime_seconds: duration_seconds(claimed_at || inserted_at, ended_at),
      total_seconds: duration_seconds(inserted_at, ended_at),
      review_wait_seconds:
        if(delegation.status == "completed" and delegation.integration_status == "pending",
          do: duration_seconds(completed_at, now),
          else: nil
        ),
      idle_update_seconds: duration_seconds(updated_at, now),
      started_at: claimed_at,
      completed_at: completed_at,
      inserted_at: inserted_at,
      updated_at: updated_at,
      timing_state: delegation_timing_state(delegation)
    }
  end

  defp delegation_timing_state(%Delegation{status: "completed", integration_status: "pending"}),
    do: "awaiting_review"

  defp delegation_timing_state(%Delegation{status: "completed"}), do: "integrated"
  defp delegation_timing_state(%Delegation{status: status}), do: status

  defp active_timing_summary(active, samples, now, limit) do
    estimates = timing_estimates(samples)

    items =
      active
      |> Enum.map(&active_timing_item(&1, estimates, now))
      |> Enum.sort_by(&active_timing_sort_key/1)

    %{
      total: length(items),
      queued: Enum.count(items, &(&1.status == "queued")),
      running: Enum.count(items, &(&1.status == "running")),
      blocked: Enum.count(items, &(&1.status == "blocked")),
      long_running: Enum.count(items, & &1.long_running),
      oldest_age_seconds: max_metric(items, :total_seconds),
      items: Enum.take(items, limit)
    }
  end

  defp active_timing_item(%Delegation{} = delegation, estimates, now) do
    timing = delegation_timing(delegation, now)
    estimate_seconds = estimate_runtime_seconds(delegation, estimates)
    elapsed_seconds = timing.runtime_seconds || timing.total_seconds || 0
    long_running_after = long_running_threshold(estimate_seconds)

    %{
      delegation_id: delegation.delegation_id,
      status: delegation.status,
      project: delegation.project,
      ref: delegation.ref,
      agent_kind: delegation.agent_kind,
      owner: delegation.owner,
      priority: delegation.priority,
      title: delegation.title,
      timing: timing,
      estimate_seconds: estimate_seconds,
      long_running_after_seconds: long_running_after,
      long_running: delegation.status == "running" and elapsed_seconds > long_running_after
    }
  end

  defp assignment_recommendation(active, pending_reviews, opts) do
    target_parallel = Keyword.get(opts, :target_parallel, 3)
    available_slots = max(target_parallel - active.running, 0)

    cond do
      pending_reviews.total > 0 ->
        %{
          target_parallel: target_parallel,
          recommended_new_starts: 0,
          reason: "integrate completed delegation reviews before starting more work"
        }

      active.long_running > 0 ->
        %{
          target_parallel: target_parallel,
          recommended_new_starts: 0,
          reason: "inspect long-running delegations before increasing parallelism"
        }

      active.blocked > 0 ->
        %{
          target_parallel: target_parallel,
          recommended_new_starts: 0,
          reason: "resolve blocked delegations before assigning new work"
        }

      active.queued == 0 ->
        %{
          target_parallel: target_parallel,
          recommended_new_starts: 0,
          reason: "no queued delegations are waiting to start"
        }

      available_slots == 0 ->
        %{
          target_parallel: target_parallel,
          recommended_new_starts: 0,
          reason: "target parallelism is already saturated"
        }

      true ->
        %{
          target_parallel: target_parallel,
          recommended_new_starts: min(active.queued, available_slots),
          reason: "start queued delegations up to the target parallelism"
        }
    end
  end

  defp pending_review_timing_summary(pending_reviews, now, limit) do
    items =
      pending_reviews
      |> Enum.map(fn delegation ->
        review = review_card(delegation)
        timing = delegation_timing(delegation, now)

        %{
          delegation_id: delegation.delegation_id,
          decision: review.decision,
          status: delegation.status,
          project: delegation.project,
          ref: delegation.ref,
          agent_kind: delegation.agent_kind,
          title: delegation.title,
          summary: review.summary,
          review_wait_seconds: timing.review_wait_seconds,
          stale: (timing.review_wait_seconds || 0) > @stale_review_after_seconds,
          timing: timing
        }
      end)
      |> Enum.sort_by(&{not &1.stale, -(&1.review_wait_seconds || 0)})

    %{
      total: length(items),
      stale: Enum.count(items, & &1.stale),
      oldest_wait_seconds: max_metric(items, :review_wait_seconds),
      items: Enum.take(items, limit)
    }
  end

  defp timing_estimates(samples) do
    %{
      global: timing_stats(samples),
      by_agent_kind: grouped_timing_stats(samples, :agent_kind),
      by_project: grouped_timing_stats(samples, :project)
    }
  end

  defp estimate_runtime_seconds(delegation, estimates) do
    [
      get_in(estimates, [:by_agent_kind, delegation.agent_kind, :median_runtime_seconds]),
      get_in(estimates, [:by_project, delegation.project, :median_runtime_seconds]),
      get_in(estimates, [:global, :median_runtime_seconds])
    ]
    |> Enum.find(&is_integer/1)
  end

  defp long_running_threshold(nil), do: @long_running_floor_seconds

  defp long_running_threshold(estimate_seconds) do
    max(@long_running_floor_seconds, estimate_seconds * 2)
  end

  defp active_timing_sort_key(item) do
    long_running_rank = if item.long_running, do: 0, else: 1
    {-item.priority, long_running_rank, -(get_in(item, [:timing, :total_seconds]) || 0)}
  end

  defp timing_stats(samples) do
    runtime_seconds =
      samples
      |> Enum.map(& &1.runtime_seconds)
      |> Enum.filter(&is_integer/1)

    total_seconds =
      samples
      |> Enum.map(& &1.total_seconds)
      |> Enum.filter(&is_integer/1)

    %{
      samples: length(runtime_seconds),
      average_runtime_seconds: average(runtime_seconds),
      median_runtime_seconds: percentile(runtime_seconds, 50),
      p90_runtime_seconds: percentile(runtime_seconds, 90),
      min_runtime_seconds: min_metric(runtime_seconds),
      max_runtime_seconds: max_metric(runtime_seconds),
      average_total_seconds: average(total_seconds),
      median_total_seconds: percentile(total_seconds, 50)
    }
  end

  defp grouped_timing_stats(samples, key) do
    samples
    |> Enum.group_by(&Map.get(&1, key, ""))
    |> Map.new(fn {group, group_samples} -> {group, timing_stats(group_samples)} end)
  end

  defp average([]), do: nil
  defp average(values), do: round(Enum.sum(values) / length(values))

  defp percentile([], _percentile), do: nil

  defp percentile(values, percentile) do
    values = Enum.sort(values)
    index = ceil(length(values) * percentile / 100) - 1
    Enum.at(values, max(index, 0))
  end

  defp min_metric([]), do: nil
  defp min_metric(values), do: Enum.min(values)

  defp max_metric([]), do: nil
  defp max_metric(values) when is_list(values), do: Enum.max(values)

  defp max_metric(items, key) do
    items
    |> Enum.map(&Map.get(&1, key))
    |> Enum.filter(&is_integer/1)
    |> max_metric()
  end

  defp duration_seconds(nil, _finish), do: nil
  defp duration_seconds(_start, nil), do: nil

  defp duration_seconds(start, finish) do
    max(DateTime.diff(finish, start, :second), 0)
  end

  defp review_decision(
         delegation,
         failed_evidence,
         forbidden_touches,
         outside_write_paths,
         warnings
       ) do
    cond do
      delegation.status != "completed" ->
        "hold"

      forbidden_touches != [] or failed_evidence != [] ->
        "reject"

      outside_write_paths != [] or "no structured evidence recorded" in warnings ->
        "revise"

      warnings == [] ->
        "accept"

      true ->
        "hold"
    end
  end

  defp review_summary("accept", _warnings), do: "ready to accept"
  defp review_summary("revise", warnings), do: "needs revision: #{Enum.join(warnings, "; ")}"
  defp review_summary("reject", warnings), do: "reject or rework: #{Enum.join(warnings, "; ")}"
  defp review_summary("hold", warnings) when warnings == [], do: "hold for foreground review"
  defp review_summary("hold", warnings), do: "hold: #{Enum.join(warnings, "; ")}"

  defp outside_write_paths(artifacts, []), do: artifacts

  defp outside_write_paths(artifacts, write_paths) do
    Enum.reject(artifacts, fn artifact ->
      Enum.any?(write_paths, &path_within?(artifact, &1))
    end)
  end

  defp forbidden_touches(artifacts, forbidden_paths) do
    Enum.filter(artifacts, fn artifact ->
      Enum.any?(forbidden_paths, &path_overlaps?(artifact, &1))
    end)
  end

  defp path_within?(path, owner_path) do
    path = normalize_path(path)
    owner_path = normalize_path(owner_path)

    path == owner_path or String.starts_with?(path, owner_path <> "/")
  end

  defp path_overlaps?(left, right) do
    left = normalize_path(left)
    right = normalize_path(right)

    cond do
      left == "" or right == "" -> false
      left == right -> true
      String.starts_with?(left, right <> "/") -> true
      String.starts_with?(right, left <> "/") -> true
      true -> false
    end
  end

  defp normalize_path(path) do
    path
    |> to_string()
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.split("/", trim: true)
    |> normalize_path_segments([])
    |> Enum.join("/")
  end

  defp normalize_path_segments([], acc), do: Enum.reverse(acc)
  defp normalize_path_segments(["." | rest], acc), do: normalize_path_segments(rest, acc)

  defp normalize_path_segments([".." | rest], [".." | _] = acc),
    do: normalize_path_segments(rest, [".." | acc])

  defp normalize_path_segments([".." | rest], [_segment | acc]),
    do: normalize_path_segments(rest, acc)

  defp normalize_path_segments([".." | rest], []), do: normalize_path_segments(rest, [".."])

  defp normalize_path_segments([segment | rest], acc),
    do: normalize_path_segments(rest, [segment | acc])

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status),
    do: where(query, [delegation], delegation.status == ^status)

  defp maybe_filter_project(query, nil), do: query

  defp maybe_filter_project(query, project),
    do: where(query, [delegation], delegation.project == ^project)

  defp maybe_filter_ref(query, nil), do: query
  defp maybe_filter_ref(query, ref), do: where(query, [delegation], delegation.ref == ^ref)

  defp maybe_filter_owner(query, nil), do: query

  defp maybe_filter_owner(query, owner),
    do: where(query, [delegation], delegation.owner == ^owner)

  defp maybe_filter_agent_kind(query, nil), do: query

  defp maybe_filter_agent_kind(query, agent_kind),
    do: where(query, [delegation], delegation.agent_kind == ^agent_kind)

  defp evidence_entries(attrs) do
    attrs
    |> Map.get(:evidence, [])
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, entries} ->
      case evidence_entry(attrs) do
        {:ok, entry} -> {:cont, {:ok, entries ++ [entry]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp evidence_entry(attrs) do
    attrs = Map.new(attrs || %{})
    command = clean(Map.get(attrs, :command) || Map.get(attrs, "command"))
    cwd = clean(Map.get(attrs, :cwd) || Map.get(attrs, "cwd"))
    exit_status = Map.get(attrs, :exit_status) || Map.get(attrs, "exit_status")

    cond do
      blank?(command) ->
        {:error, {:invalid_evidence, "evidence requires command"}}

      blank?(cwd) ->
        {:error, {:invalid_evidence, "evidence requires cwd"}}

      is_nil(exit_status) ->
        {:error, {:invalid_evidence, "evidence requires exit status"}}

      true ->
        {:ok,
         %{
           "evidence_id" => evidence_id(),
           "kind" => clean(Map.get(attrs, :kind) || Map.get(attrs, "kind") || "command"),
           "command" => command,
           "cwd" => cwd,
           "exit_status" => exit_status(exit_status),
           "status" => evidence_status(exit_status(exit_status)),
           "output_excerpt" =>
             attrs
             |> Map.get(:output_excerpt, Map.get(attrs, "output_excerpt", ""))
             |> clean()
             |> truncate(4_000),
           "artifacts" =>
             json_list(Map.get(attrs, :artifacts) || Map.get(attrs, "artifacts") || []),
           "risks" => json_list(Map.get(attrs, :risks) || Map.get(attrs, "risks") || []),
           "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
         }}
    end
  end

  defp exit_status(value) when is_integer(value), do: value

  defp exit_status(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> -1
    end
  end

  defp exit_status(_value), do: -1

  defp evidence_status(0), do: "passed"
  defp evidence_status(_status), do: "failed"

  defp append_json(existing_json, entries) do
    existing_json
    |> decode_json_list()
    |> Kernel.++(entries)
    |> encode_json()
  end

  defp merge_json_lists(existing_json, values) do
    existing_json
    |> decode_json_list()
    |> merge_lists(values)
    |> encode_json()
  end

  defp merge_lists(existing, values) do
    (json_list(existing) ++ json_list(values))
    |> Enum.uniq()
  end

  defp json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      _other -> [value]
    end
    |> normalize_json_list()
  end

  defp json_list(value) when is_list(value), do: normalize_json_list(value)
  defp json_list(_value), do: []

  defp normalize_json_list(values) do
    values
    |> Enum.map(&normalize_json_list_value/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp normalize_json_list_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_json_list_value(value), do: value

  defp latest_evidence(evidence_json) do
    evidence_json
    |> decode_json_list()
    |> List.last()
  end

  defp render_evidence_list([]), do: []

  defp render_evidence_list(entries) do
    Enum.map(entries, fn entry ->
      [
        Map.get(entry, "status", "unknown"),
        Map.get(entry, "kind", "command"),
        Map.get(entry, "command", ""),
        "exit=#{Map.get(entry, "exit_status", "")}",
        Map.get(entry, "cwd", "")
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" | ")
    end)
  end

  defp open_delegations do
    Delegation
    |> where([delegation], delegation.status in ["queued", "running", "blocked"])
    |> Repo.all()
  end

  defp encode_json_field(attrs, key, default) do
    Map.update(attrs, key, encode_json(default), &encode_json/1)
  end

  defp maybe_encode_json_field(attrs, key) do
    if Map.has_key?(attrs, key), do: Map.update!(attrs, key, &encode_json/1), else: attrs
  end

  defp encode_json(value) when is_binary(value), do: value
  defp encode_json(value), do: Jason.encode!(value)

  defp decode_json_list(value) do
    case Jason.decode(value || "[]") do
      {:ok, list} when is_list(list) -> list
      _other -> []
    end
  end

  defp count_by(items, fun) do
    items
    |> Enum.map(fun)
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
  end

  defp blank_value?([]), do: true
  defp blank_value?(value), do: blank?(value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp clean(nil), do: ""
  defp clean(value), do: String.trim(to_string(value))

  defp truncate(value, max) do
    if String.length(value) > max do
      String.slice(value, 0, max)
    else
      value
    end
  end

  defp delegation_id do
    @delegation_prefix <>
      (5
       |> :crypto.strong_rand_bytes()
       |> Base.encode16(case: :lower))
  end

  defp evidence_id do
    "ev-" <>
      (5
       |> :crypto.strong_rand_bytes()
       |> Base.encode16(case: :lower))
  end
end
