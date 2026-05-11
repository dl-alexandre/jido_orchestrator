defmodule JX.PortfolioSummary do
  @moduledoc """
  Builds project-level portfolio summaries from registered projects and session
  profile reports.
  """

  @pr_pattern ~r/(?:PR|pull request)\s*#?(\d+)/i
  @max_refs_per_project 12

  alias JX.BlockedReasons
  alias JX.ProjectMatcher

  def build(projects, profile_report, opts \\ []) do
    limit = Keyword.get(opts, :limit, 25)
    registered_projects = Enum.map(projects, &registered_project/1)
    registry_by_name = Enum.group_by(registered_projects, & &1.name)

    profiles_by_project =
      Enum.group_by(profile_report.profiles, &project_name(&1, registered_projects))

    projects =
      registered_projects
      |> Enum.map(& &1.name)
      |> Kernel.++(Map.keys(profiles_by_project))
      |> Enum.uniq()
      |> Enum.map(fn name ->
        portfolio_project(
          name,
          Map.get(profiles_by_project, name, []),
          Map.get(registry_by_name, name, [])
        )
      end)
      |> Enum.sort_by(&project_sort_key/1)

    %{
      generated_at: DateTime.utc_now(),
      observed: profile_report.observed,
      observation_refresh: profile_report.observation_refresh,
      totals: portfolio_totals(projects, registered_projects),
      registered_projects: registered_projects,
      projects_total: length(projects),
      returned: min(length(projects), limit),
      projects: Enum.take(projects, limit),
      errors: profile_report.errors
    }
  end

  defp registered_project(project) do
    host = Map.get(project, :host)

    %{
      name: project.name,
      slug: project.slug,
      registered: true,
      host: (host && host.name) || "",
      transport: (host && host.transport) || "",
      ssh_target: (host && host.ssh_target) || "",
      workspace_path: (host && host.workspace_path) || "",
      repo_path: project.repo_path
    }
  end

  defp portfolio_project(name, profiles, registered_projects) do
    active_host = first_present(unique_texts(profiles, [:session, :host]))
    repo_paths = profile_repo_paths(profiles)

    base =
      registered_project_base(name, registered_projects, active_host, repo_paths)

    refs = Enum.map(profiles, &session_ref/1)

    base
    |> Map.merge(%{
      sessions_total: length(profiles),
      instances_total: length(registered_projects),
      instances: registered_projects,
      sample_path: first_present(profile_paths(profiles)) || "",
      repo_roots: unique_texts(profiles, [:actual, :repo, :root]),
      refs: Enum.take(refs, @max_refs_per_project),
      by_state: count_by(profiles, &state/1),
      by_work_state: count_by(profiles, &work_state/1),
      by_prompt: count_by(profiles, &prompt_status/1),
      by_control: count_by(profiles, &control_mode/1),
      agents: unique_texts(profiles, [:session, :agent_name]),
      branches: unique_branches(profiles),
      prs: extract_prs(profiles),
      blockers: unique_blockers(profiles),
      risks: unique_risks(profiles),
      blocked_total: Enum.count(profiles, &blocked?/1),
      blocked_by_reason: BlockedReasons.urgent_counts(profiles),
      blocked_reasons: BlockedReasons.counts(profiles),
      parked_total: Enum.count(profiles, &BlockedReasons.parked?/1),
      done_total: Enum.count(profiles, &BlockedReasons.done?/1),
      ready_total: Enum.count(profiles, &ready?/1),
      draft_total: Enum.count(profiles, &draft?/1),
      awaiting_total: Enum.count(profiles, &awaiting_observation?/1),
      running_total: Enum.count(profiles, &running?/1),
      attention_total: Enum.count(profiles, &needs_attention?/1),
      directable_total: Enum.count(profiles, &directable?/1),
      focus: project_focus(profiles),
      next_action: project_next_action(profiles)
    })
  end

  defp registered_project_base(name, [], active_host, repo_paths) do
    %{
      name: name,
      slug: "",
      registered: false,
      host: active_host || "",
      transport: "",
      ssh_target: "",
      workspace_path: "",
      repo_path: first_present(repo_paths) || ""
    }
  end

  defp registered_project_base(_name, [project], _active_host, _repo_paths), do: project

  defp registered_project_base(name, projects, _active_host, _repo_paths) do
    hosts = unique_project_values(projects, :host)
    repo_paths = unique_project_values(projects, :repo_path)

    %{
      name: name,
      slug: "",
      registered: true,
      host: Enum.join(hosts, ","),
      transport: "multi",
      ssh_target: "",
      workspace_path: "",
      repo_path: Enum.join(repo_paths, ",")
    }
  end

  defp project_name(profile, registered_projects) do
    ProjectMatcher.name_for_profile(profile, registered_projects)
  end

  defp session_ref(profile) do
    %{
      ref: profile.ref,
      state: state(profile),
      work_state: work_state(profile),
      prompt_status: prompt_status(profile),
      control_mode: control_mode(profile),
      can_direct: directable?(profile),
      blocked_reason: get_in(profile, [:blocked, :primary]) || "",
      urgent_blocked: BlockedReasons.urgent?(profile),
      next_step: profile.next_step || "",
      focus: profile_focus(profile),
      branch: get_in(profile, [:actual, :repo, :branch]) || "",
      prs: extract_prs([profile])
    }
  end

  defp portfolio_totals(projects, registered_projects) do
    %{
      registered_projects: length(registered_projects),
      projects_total: length(projects),
      active_projects: Enum.count(projects, &(&1.sessions_total > 0)),
      unregistered_workstreams:
        Enum.count(projects, &(!&1.registered and &1.name != "unassigned")),
      sessions_total: Enum.sum(Enum.map(projects, & &1.sessions_total)),
      blocked_sessions: Enum.sum(Enum.map(projects, & &1.blocked_total)),
      blocked_by_reason: sum_reason_counts(projects, :blocked_by_reason),
      blocked_reasons: sum_reason_counts(projects, :blocked_reasons),
      parked_sessions: Enum.sum(Enum.map(projects, & &1.parked_total)),
      done_sessions: Enum.sum(Enum.map(projects, & &1.done_total)),
      ready_sessions: Enum.sum(Enum.map(projects, & &1.ready_total)),
      draft_sessions: Enum.sum(Enum.map(projects, & &1.draft_total)),
      awaiting_observation: Enum.sum(Enum.map(projects, & &1.awaiting_total)),
      running_sessions: Enum.sum(Enum.map(projects, & &1.running_total)),
      attention_sessions: Enum.sum(Enum.map(projects, & &1.attention_total)),
      directable_sessions: Enum.sum(Enum.map(projects, & &1.directable_total))
    }
  end

  defp project_sort_key(project) do
    {
      -project.ready_total,
      -project.awaiting_total,
      -project.running_total,
      -project.blocked_total,
      -project.attention_total,
      -project.sessions_total,
      if(project.registered, do: 0, else: 1),
      project.name
    }
  end

  defp state(profile), do: get_in(profile, [:comparison, :state]) || ""
  defp work_state(profile), do: get_in(profile, [:actual, :work_state]) || ""
  defp prompt_status(profile), do: get_in(profile, [:next_prompt, :status]) || ""
  defp control_mode(profile), do: get_in(profile, [:session, :control_mode]) || ""

  defp blocked?(profile), do: BlockedReasons.urgent?(profile)

  defp ready?(profile), do: state(profile) == "ready-to-send" or prompt_status(profile) == "ready"
  defp draft?(profile), do: prompt_status(profile) == "draft"
  defp awaiting_observation?(profile), do: state(profile) == "awaiting-observation"
  defp running?(profile), do: work_state(profile) == "running"
  defp needs_attention?(profile), do: state(profile) == "needs-attention"
  defp directable?(profile), do: get_in(profile, [:session, :can_direct]) == true

  defp project_next_action([]), do: "registered; no active sessions observed"

  defp project_next_action(profiles) do
    text = profiles_text(profiles)

    cond do
      commit_push_ready?(text) ->
        "review diff, commit, and push if scope is clean"

      Enum.any?(profiles, &ready?/1) ->
        "send chambered prompt"

      Enum.any?(profiles, &awaiting_observation?/1) ->
        "observe sent work"

      Enum.any?(profiles, &running?/1) ->
        "observe when session settles"

      upstream_hold?(text) ->
        "hold for upstream/runtime blocker"

      Enum.any?(profiles, &blocked?/1) ->
        "resolve blocked session before prompting"

      Enum.any?(profiles, &draft?/1) ->
        "review chambered draft"

      Enum.any?(profiles, &needs_attention?/1) ->
        "review attention session"

      true ->
        "track"
    end
  end

  defp commit_push_ready?(text) do
    String.contains?(text, "commit/push") or
      String.contains?(text, "commit and push") or
      Regex.match?(~r/\bready to commit\b.*\bpush\b|\bready to push\b.*\bcommit\b/i, text)
  end

  defp upstream_hold?(text) do
    String.contains?(text, "upstream") and
      Enum.any?(["hold", "wait", "blocked", "environmental", "develop green"], fn marker ->
        String.contains?(text, marker)
      end)
  end

  defp profiles_text(profiles) do
    profiles
    |> Enum.flat_map(&profile_texts/1)
    |> Enum.join("\n")
    |> String.downcase()
  end

  defp profile_texts(profile) do
    [
      profile.next_step,
      get_in(profile, [:comparison, :actual_summary]),
      get_in(profile, [:planned, :summary]),
      get_in(profile, [:planned, :objective]),
      get_in(profile, [:planned, :strategy]),
      get_in(profile, [:planned, :notes]),
      get_in(profile, [:actual, :task]),
      get_in(profile, [:actual, :summary]),
      get_in(profile, [:actual, :title]),
      get_in(profile, [:next_prompt, :text])
    ]
    |> Enum.filter(&text_present?/1)
  end

  defp project_focus([]), do: ""

  defp project_focus(profiles) do
    profiles
    |> Enum.map(&profile_focus/1)
    |> Enum.find("", &text_present?/1)
  end

  defp profile_focus(profile) do
    first_present([
      get_in(profile, [:planned, :objective]),
      get_in(profile, [:planned, :summary]),
      get_in(profile, [:comparison, :actual_summary]),
      get_in(profile, [:actual, :summary]),
      get_in(profile, [:actual, :task]),
      get_in(profile, [:session, :current_path])
    ]) || ""
  end

  defp count_by(items, fun) when is_function(fun, 1) do
    items
    |> Enum.map(fun)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
  end

  defp unique_texts(profiles, path) do
    profiles
    |> Enum.map(&get_in(&1, path))
    |> Enum.filter(&text_present?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp unique_project_values(projects, key) do
    projects
    |> Enum.map(&Map.get(&1, key, ""))
    |> Enum.filter(&text_present?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp unique_branches(profiles) do
    profiles
    |> unique_texts([:actual, :repo, :branch])
    |> Enum.reject(&(&1 == "HEAD"))
  end

  defp profile_repo_paths(profiles) do
    case unique_texts(profiles, [:actual, :repo, :root]) do
      [] -> profile_paths(profiles)
      roots -> roots
    end
  end

  defp profile_paths(profiles) do
    unique_texts(profiles, [:session, :current_path])
  end

  defp unique_blockers(profiles) do
    profiles
    |> Enum.flat_map(&(get_in(&1, [:comparison, :repo_blockers]) || []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp unique_risks(profiles) do
    profiles
    |> Enum.flat_map(&(get_in(&1, [:comparison, :repo_risks]) || []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp sum_reason_counts(projects, key) do
    Enum.reduce(projects, %{}, fn project, counts ->
      project
      |> Map.get(key, %{})
      |> Enum.reduce(counts, fn {reason, count}, acc ->
        Map.update(acc, reason, count, &(&1 + count))
      end)
    end)
  end

  defp extract_prs(profiles) do
    profiles
    |> Enum.flat_map(&profile_texts/1)
    |> Enum.flat_map(fn text ->
      @pr_pattern
      |> Regex.scan(text)
      |> Enum.map(fn [_match, number] -> "##{number}" end)
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&String.trim_leading(&1, "#"))
  end

  defp first_present(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end)
  end

  defp text_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp text_present?(_value), do: false
end
