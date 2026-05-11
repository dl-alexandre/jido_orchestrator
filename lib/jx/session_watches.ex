defmodule JX.SessionWatches do
  @moduledoc """
  Durable watch contracts for background session monitoring.

  A watch says what completion and blocker evidence should look like. Monitor
  scans evaluate active watches against fresh profile observations.
  """

  import Ecto.Query

  alias JX.Repo
  alias JX.SessionObservations.SessionObservation
  alias JX.SessionWatches.SessionWatch

  @watch_prefix "wat-"

  def statuses, do: SessionWatch.statuses()
  def modes, do: SessionWatch.modes()

  def add_watch(ref, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:watch_id, watch_id())
      |> Map.put(:ref, ref)
      |> Map.put_new(:status, "active")
      |> Map.put_new(:mode, "notify")

    %SessionWatch{}
    |> SessionWatch.changeset(attrs)
    |> Repo.insert()
  end

  def list_watches(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    SessionWatch
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_ref(Keyword.get(opts, :ref))
    |> order_by([watch], desc: watch.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def get_watch(watch_id), do: Repo.get_by(SessionWatch, watch_id: watch_id)

  def complete(watch_id, summary) do
    update_terminal(watch_id, "completed", summary)
  end

  def cancel(watch_id, summary) do
    update_terminal(watch_id, "cancelled", summary)
  end

  def evaluate_profiles(profiles) do
    profiles_by_ref = Map.new(profiles, &{&1.ref, &1})

    watches = list_watches(status: "active", limit: 500)
    observations_by_ref = latest_observations_by_ref(Enum.map(watches, & &1.ref))

    watches
    |> Enum.flat_map(fn watch ->
      case Map.get(profiles_by_ref, watch.ref) do
        nil -> []
        profile -> [evaluate_profile(watch, profile, Map.get(observations_by_ref, watch.ref))]
      end
    end)
  end

  def evaluate_watch(%SessionWatch{} = watch, profile) do
    evaluate_profile(watch, profile, latest_observation(watch.ref))
  end

  defp evaluate_profile(watch, profile, observation) do
    evidence = evidence_text(profile, observation)
    now = DateTime.utc_now()
    summary = profile_summary(profile)

    cond do
      pattern_match?(watch.success_pattern, evidence) ->
        attrs = %{
          status: "completed",
          last_summary: summary,
          result_summary: watch_result("success", watch.success_pattern, summary),
          last_observed_at: now,
          completed_at: now
        }

        update_watch(watch, attrs, profile)

      pattern_match?(watch.blocker_pattern, evidence) ->
        attrs = %{
          status: "blocked",
          last_summary: summary,
          result_summary: watch_result("blocker", watch.blocker_pattern, summary),
          last_observed_at: now,
          completed_at: now
        }

        update_watch(watch, attrs, profile)

      true ->
        update_watch(watch, %{last_summary: summary, last_observed_at: now}, profile)
    end
  end

  defp update_watch(watch, attrs, profile) do
    {:ok, updated} =
      watch
      |> SessionWatch.changeset(attrs)
      |> Repo.update()

    %{
      watch: updated,
      previous_status: watch.status,
      status: updated.status,
      changed?: watch.status != updated.status,
      profile: profile,
      summary: updated.result_summary || updated.last_summary || ""
    }
  end

  defp update_terminal(watch_id, status, summary) do
    case get_watch(watch_id) do
      nil ->
        {:error, :watch_not_found}

      watch ->
        now = DateTime.utc_now()

        watch
        |> SessionWatch.changeset(%{
          status: status,
          result_summary: summary || "",
          completed_at: now
        })
        |> Repo.update()
    end
  end

  defp pattern_match?("", _evidence), do: false
  defp pattern_match?(nil, _evidence), do: false

  defp pattern_match?(pattern, evidence) do
    case Regex.compile(pattern, "i") do
      {:ok, regex} ->
        Regex.match?(regex, evidence)

      {:error, _reason} ->
        evidence
        |> String.downcase()
        |> String.contains?(String.downcase(pattern))
    end
  end

  defp evidence_text(profile, observation) do
    [
      get_in(profile, [:actual, :summary]),
      get_in(profile, [:actual, :task]),
      get_in(profile, [:comparison, :actual_summary]),
      get_in(profile, [:actual, :last_directive, :message]),
      observation_output(observation),
      get_in(profile, [:planned, :summary]),
      get_in(profile, [:planned, :objective]),
      get_in(profile, [:planned, :notes]),
      get_in(profile, [:next_prompt, :text]),
      profile.next_step
    ]
    |> Enum.filter(&present?/1)
    |> Enum.join("\n")
  end

  defp observation_output(nil), do: ""

  defp observation_output(%SessionObservation{snapshot: snapshot, summary: summary}) do
    case Jason.decode(snapshot || "") do
      {:ok, %{"capture" => %{"output" => output}}} when is_binary(output) ->
        output

      _other ->
        summary || ""
    end
  end

  defp profile_summary(profile) do
    [
      get_in(profile, [:comparison, :actual_summary]),
      get_in(profile, [:actual, :summary]),
      get_in(profile, [:actual, :task]),
      profile.next_step
    ]
    |> Enum.find("", &present?/1)
    |> truncate(500)
  end

  defp watch_result(kind, pattern, summary) do
    "#{kind} matched #{inspect(pattern)}: #{summary}"
    |> truncate(500)
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [watch], watch.status == ^status)

  defp maybe_filter_ref(query, nil), do: query
  defp maybe_filter_ref(query, ref), do: where(query, [watch], watch.ref == ^ref)

  defp latest_observations_by_ref(refs) do
    refs
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> case do
      [] ->
        %{}

      refs ->
        refs_set = MapSet.new(refs)

        SessionObservation
        |> where([observation], observation.ref in ^refs)
        |> order_by([observation], desc: observation.id)
        |> Repo.all()
        |> Enum.filter(&MapSet.member?(refs_set, &1.ref))
        |> Enum.reduce(%{}, fn observation, acc ->
          Map.put_new(acc, observation.ref, observation)
        end)
    end
  end

  defp latest_observation(ref) when ref in [nil, ""], do: nil

  defp latest_observation(ref) do
    SessionObservation
    |> where([observation], observation.ref == ^ref)
    |> order_by([observation], desc: observation.id)
    |> limit(1)
    |> Repo.one()
  end

  defp watch_id do
    random =
      5
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    @watch_prefix <> random
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp truncate(value, max) when byte_size(value) <= max, do: value
  defp truncate(value, max), do: binary_part(value, 0, max) <> "..."
end
