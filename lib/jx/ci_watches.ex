defmodule JX.CiWatches do
  @moduledoc """
  Durable GitHub Actions PR watches.

  CI watches let the orchestrator track external PR state without tying that
  state to one visible agent pane. They are intentionally read-only except for
  optional profile updates when a watched PR reaches a terminal state.
  """

  import Ecto.Query

  alias JX.CiDigest
  alias JX.CiWatches.CiWatch
  alias JX.OrchestrationActions
  alias JX.Repo
  alias JX.SessionProfiles

  @watch_prefix "ciw-"

  def statuses, do: CiWatch.statuses()
  def modes, do: CiWatch.modes()

  def add_watch(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:watch_id, watch_id())
      |> Map.put_new(:status, "active")
      |> Map.put_new(:mode, "notify")

    %CiWatch{}
    |> CiWatch.changeset(attrs)
    |> Repo.insert()
  end

  def list_watches(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    CiWatch
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_repo(Keyword.get(opts, :repo))
    |> maybe_filter_ref(Keyword.get(opts, :ref))
    |> maybe_filter_project(Keyword.get(opts, :project))
    |> order_by([watch], desc: watch.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def get_watch(watch_id), do: Repo.get_by(CiWatch, watch_id: watch_id)

  def review_watch(watch_id, opts \\ []) do
    with %CiWatch{} = watch <- get_watch(watch_id),
         {:ok, digest} <-
           CiDigest.run(watch.repo, watch.pr_number, logs: Keyword.get(opts, :logs, true)) do
      {:ok, apply_digest(watch, digest)}
    else
      nil -> {:error, :ci_watch_not_found}
      other -> other
    end
  end

  def evaluate_active(opts \\ []) do
    opts
    |> Keyword.put(:status, "active")
    |> list_watches()
    |> Enum.map(&evaluate_watch(&1, opts))
  end

  def apply_digest(%CiWatch{} = watch, digest) do
    previous_status = watch.status
    attrs = digest_attrs(watch, digest)

    {:ok, updated} =
      watch
      |> CiWatch.changeset(attrs)
      |> Repo.update()

    changed? = previous_status != updated.status
    update = build_update(watch, updated, previous_status, changed?, digest)

    case profile_action(update) do
      nil -> update
      action -> Map.put(update, :profile_action, apply_profile_action(update, action))
    end
  end

  def cancel_watch(watch_id, summary) do
    case get_watch(watch_id) do
      nil ->
        {:error, :ci_watch_not_found}

      watch ->
        watch
        |> CiWatch.changeset(%{
          status: "cancelled",
          last_summary: summary || "manual cancel",
          completed_at: DateTime.utc_now()
        })
        |> Repo.update()
    end
  end

  defp evaluate_watch(watch, opts) do
    case CiDigest.run(watch.repo, watch.pr_number, logs: Keyword.get(opts, :logs, true)) do
      {:ok, digest} ->
        apply_digest(watch, digest)

      {:error, reason} ->
        now = DateTime.utc_now()
        summary = "ci digest failed: #{inspect(reason)}"

        {:ok, updated} =
          watch
          |> CiWatch.changeset(%{
            last_summary: summary,
            last_checked_at: now
          })
          |> Repo.update()

        build_update(watch, updated, watch.status, false, nil)
        |> Map.put(:error, reason)
    end
  end

  defp digest_attrs(watch, digest) do
    now = DateTime.utc_now()
    status = status_for_digest(watch, digest)
    head_sha = digest_head_sha(digest)

    attrs =
      %{
        status: status,
        last_overall: digest.overall || "",
        last_summary: digest_summary(watch, digest, status),
        last_digest: encode_digest(digest),
        last_checked_at: now
      }
      |> put_head_attrs(watch, head_sha, now)

    if status != "active" and watch.status == "active" do
      Map.put(attrs, :completed_at, now)
    else
      attrs
    end
  end

  defp put_head_attrs(attrs, _watch, "", _now), do: attrs

  defp put_head_attrs(attrs, watch, head_sha, now) do
    attrs
    |> Map.put(:last_head_sha, head_sha)
    |> Map.put(:last_head_checked_at, now)
    |> Map.put(:head_sha, first_present([watch.head_sha, head_sha]))
  end

  defp status_for_digest(watch, digest) do
    cond do
      superseded?(watch, digest) -> "superseded"
      digest.overall == "pass" -> "passed"
      digest.overall == "fail" -> "failed"
      digest.overall == "cancel" -> "cancelled"
      true -> "active"
    end
  end

  defp superseded?(watch, digest) do
    watched_head = first_present([watch.head_sha])
    current_head = digest_head_sha(digest)

    watched_head != "" and current_head != "" and watched_head != current_head
  end

  defp digest_summary(watch, digest, "superseded") do
    "PR ##{digest.pr} watch superseded: watched #{short_sha(watch.head_sha)} but current head is #{short_sha(digest_head_sha(digest))}"
  end

  defp digest_summary(_watch, %{overall: "pass", totals: totals, pr: pr}, _status) do
    "PR ##{pr} checks passed (#{Map.get(totals, "total", 0)} checks)"
  end

  defp digest_summary(_watch, %{overall: "pending", totals: totals, pr: pr}, _status) do
    "PR ##{pr} checks pending (#{Map.get(totals, "pending", 0)} pending)"
  end

  defp digest_summary(_watch, %{overall: "cancel", pr: pr}, _status) do
    "PR ##{pr} checks cancelled"
  end

  defp digest_summary(_watch, %{overall: "fail", blockers: blockers, pr: pr}, _status) do
    blocker_summary =
      blockers
      |> Enum.map(&"#{Map.get(&1, :check)}: #{Map.get(&1, :summary)}")
      |> Enum.reject(&(&1 == ": "))
      |> Enum.join("; ")
      |> truncate(220)

    if blocker_summary == "" do
      "PR ##{pr} checks failed"
    else
      "PR ##{pr} checks failed: #{blocker_summary}"
    end
  end

  defp digest_summary(_watch, %{overall: overall, pr: pr}, _status),
    do: "PR ##{pr} checks #{overall}"

  defp encode_digest(digest) do
    Jason.encode!(digest)
  rescue
    ArgumentError -> "{}"
  end

  defp build_update(previous, updated, previous_status, changed?, digest) do
    %{
      watch: updated,
      previous_status: previous_status,
      status: updated.status,
      changed?: changed?,
      digest: digest,
      summary: updated.last_summary || previous.last_summary || ""
    }
  end

  defp profile_action(%{changed?: false}), do: nil
  defp profile_action(%{watch: %{ref: ref}}) when ref in [nil, ""], do: nil
  defp profile_action(%{watch: %{mode: "notify"}}), do: nil
  defp profile_action(%{status: "superseded"}), do: nil

  defp profile_action(%{status: "passed", watch: %{mode: "prompt", success_prompt: prompt}})
       when is_binary(prompt) and prompt != "" do
    {:prompt, prompt, "watched CI passed"}
  end

  defp profile_action(%{status: "failed", watch: %{mode: "prompt", failure_prompt: prompt}})
       when is_binary(prompt) and prompt != "" do
    {:prompt, prompt, "watched CI failed"}
  end

  defp profile_action(%{status: status, watch: %{mode: mode}})
       when status in ["passed", "failed", "cancelled"] and mode in ["hold", "prompt"] do
    {:hold, "watched CI #{status}"}
  end

  defp profile_action(_update), do: nil

  defp apply_profile_action(update, {:prompt, prompt, reason}) do
    attrs = %{
      next_prompt: prompt,
      prompt_status: "draft",
      strategy: "Chambered by CI watch #{update.watch.watch_id}: #{reason}",
      notes: update.summary,
      last_seen_at: DateTime.utc_now()
    }

    update
    |> apply_profile_update("ci-chamber-prompt", attrs)
    |> Map.put(:prompt_status, "draft")
  end

  defp apply_profile_action(update, {:hold, reason}) do
    attrs = %{
      next_prompt: "",
      prompt_status: "blocked",
      strategy: "Held by CI watch #{update.watch.watch_id}: #{reason}",
      notes: update.summary,
      last_seen_at: DateTime.utc_now()
    }

    update
    |> apply_profile_update("ci-hold-profile", attrs)
    |> Map.put(:reason, reason)
  end

  defp apply_profile_update(update, action, attrs) do
    result =
      case SessionProfiles.upsert_session_profile(update.watch.ref, attrs) do
        {:ok, _profile} ->
          %{
            action: action,
            status: "executed",
            source: "ci-watch",
            watch_id: update.watch.watch_id,
            recommendation_id: update.watch.watch_id,
            ref: update.watch.ref,
            target: "#{update.watch.repo}##{update.watch.pr_number}",
            result_summary: profile_action_summary(action, update)
          }

        {:error, reason} ->
          %{
            action: action,
            status: "error",
            source: "ci-watch",
            watch_id: update.watch.watch_id,
            recommendation_id: update.watch.watch_id,
            ref: update.watch.ref,
            target: "#{update.watch.repo}##{update.watch.pr_number}",
            error: inspect(reason),
            result_summary: "CI watch profile action failed"
          }
      end

    OrchestrationActions.record_result("ci-watch", result, source: "ci-watch")
    result
  end

  defp profile_action_summary("ci-chamber-prompt", update) do
    "CI watch #{update.watch.watch_id} chambered follow-up prompt"
  end

  defp profile_action_summary("ci-hold-profile", update) do
    "CI watch #{update.watch.watch_id} held profile for review"
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [watch], watch.status == ^status)

  defp maybe_filter_repo(query, nil), do: query
  defp maybe_filter_repo(query, repo), do: where(query, [watch], watch.repo == ^repo)

  defp maybe_filter_ref(query, nil), do: query
  defp maybe_filter_ref(query, ref), do: where(query, [watch], watch.ref == ^ref)

  defp maybe_filter_project(query, nil), do: query
  defp maybe_filter_project(query, project), do: where(query, [watch], watch.project == ^project)

  defp truncate(value, max) when byte_size(value) <= max, do: value
  defp truncate(value, max), do: binary_part(value, 0, max) <> "..."

  defp digest_head_sha(digest), do: first_present([Map.get(digest, :head_sha)])

  defp first_present(values) do
    Enum.find_value(values, "", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end)
  end

  defp short_sha(value) do
    value
    |> to_string()
    |> String.slice(0, 12)
  end

  defp watch_id do
    random =
      5
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    @watch_prefix <> random
  end
end
