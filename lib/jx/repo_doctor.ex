defmodule JX.RepoDoctor do
  @moduledoc """
  Promotion-oriented health checks for registered project repositories.
  """

  alias JX.Projects.Project
  alias JX.SSH
  alias JX.Shell

  def run(project_name, projects, opts \\ []) do
    generated_at = DateTime.utc_now()
    base_branch = Keyword.get(opts, :base_branch, "develop")
    promote_branch = Keyword.get(opts, :promote_branch, "master")
    sessions = Keyword.get(opts, :sessions, [])

    instances =
      Enum.map(projects, fn project ->
        doctor_project(project, base_branch, promote_branch, sessions, generated_at)
      end)

    %{
      generated_at: generated_at,
      project: project_name,
      base_branch: base_branch,
      promote_branch: promote_branch,
      registered_instances: length(projects),
      summary: summary(instances),
      instances: instances,
      warnings: registry_warnings(project_name, projects)
    }
  end

  def passed?(%{instances: instances}) do
    Enum.all?(instances, fn instance ->
      instance.status == "ok" and Enum.all?(instance.checks, &(&1.status == :ok))
    end)
  end

  defp doctor_project(%Project{} = project, base_branch, promote_branch, sessions, observed_at) do
    base = project_base(project)

    case SSH.adapter(project.host).run(
           project.host,
           doctor_script(project.repo_path, base_branch, promote_branch)
         ) do
      {:ok, output} ->
        output
        |> parse_output(project.repo_path, base_branch, promote_branch, observed_at)
        |> add_session_checks(project, sessions)
        |> Map.merge(base)
        |> finalize_instance()

      {:error, reason} ->
        %{
          status: "error",
          error: inspect(reason),
          branch: "",
          head: "",
          upstream: "",
          remote: "",
          remote_url: "",
          remote_status: nil,
          remote_refs: %{},
          status_short: [],
          changes: [],
          worktrees: [],
          branches: [],
          orphaned_sessions: [],
          observed_at: observed_at,
          base_branch: base_branch,
          promote_branch: promote_branch,
          canonical_ref: "",
          canonical_source: "missing",
          local_ref: "",
          remote_output: [],
          tracking_refs: %{},
          checks: [fail("repo doctor command ran", inspect(reason))]
        }
        |> Map.merge(base)
        |> finalize_instance()
    end
  end

  defp project_base(project) do
    host = project.host

    %{
      project: project.name,
      slug: project.slug,
      host: host.name,
      transport: host.transport,
      ssh_target: host.ssh_target || "",
      workspace_path: host.workspace_path,
      repo_path: project.repo_path
    }
  end

  defp doctor_script(repo_path, base_branch, promote_branch) do
    repo = Shell.quote(repo_path)
    base = Shell.quote(base_branch)
    promote = Shell.quote(promote_branch)

    """
    printf 'jx-repo-doctor\t1\n'
    repo=#{repo}
    base_branch=#{base}
    promote_branch=#{promote}
    printf 'repo_path\t%s\n' "$repo"

    if [ ! -e "$repo" ]; then
      printf 'status\terror\n'
      printf 'error\trepo path missing\n'
      exit 0
    fi

    if [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; then
      printf 'status\terror\n'
      printf 'error\tnot a git repository\n'
      exit 0
    fi

    if ! cd "$repo"; then
      printf 'status\terror\n'
      printf 'error\tcould not cd into repo path\n'
      exit 0
    fi

    remote="$(git remote 2>/dev/null | head -n 1 || true)"
    printf 'status\tok\n'
    printf 'branch\t%s\n' "$(git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    printf 'head\t%s\n' "$(git rev-parse --verify HEAD 2>/dev/null || true)"
    printf 'upstream\t%s\n' "$(git rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null || true)"
    printf 'remote\t%s\n' "$remote"
    printf 'remote_url\t%s\n' "$(git remote get-url "$remote" 2>/dev/null || true)"

    remote_status=0
    printf 'remote_refs_start\n'
    if [ -n "$remote" ]; then
      git ls-remote --heads "$remote" "$base_branch" "$promote_branch" 2>&1 || remote_status=$?
    else
      printf 'no git remote configured\n'
      remote_status=1
    fi
    printf 'remote_refs_end\n'
    printf 'remote_status\t%s\n' "$remote_status"

    printf 'tracking_refs_start\n'
    if [ -n "$remote" ]; then
      for branch in "$base_branch" "$promote_branch"; do
        [ -n "$branch" ] || continue
        tracking_ref="refs/remotes/$remote/$branch"
        tracking_sha="$(git rev-parse --verify "$tracking_ref" 2>/dev/null || true)"
        if [ -n "$tracking_sha" ]; then
          printf '%s\t%s\n' "$tracking_sha" "$tracking_ref"
        fi
      done
    fi
    printf 'tracking_refs_end\n'

    printf 'status_short_start\n'
    git status --short --branch 2>&1 || true
    printf 'status_short_end\n'
    printf 'worktree_start\n'
    git worktree list --porcelain 2>/dev/null || true
    printf 'worktree_end\n'
    printf 'branches_start\n'
    git for-each-ref refs/heads --format='%(refname:short)%09%(upstream:short)%09%(upstream:track)%09%(objectname)%09%(subject)' 2>/dev/null || true
    printf 'branches_end\n'
    """
  end

  defp parse_output(output, repo_path, base_branch, promote_branch, observed_at) do
    lines = String.split(output, "\n", trim: false)
    fields = parse_fields(lines)
    status_short = section(lines, "status_short_start", "status_short_end")
    changes = Enum.reject(status_short, &status_branch_line?/1)
    remote_ref_lines = section(lines, "remote_refs_start", "remote_refs_end")
    remote_refs = parse_remote_refs(remote_ref_lines)

    tracking_refs =
      parse_tracking_refs(section(lines, "tracking_refs_start", "tracking_refs_end"))

    worktrees = parse_worktrees(section(lines, "worktree_start", "worktree_end"))
    branches = parse_branches(section(lines, "branches_start", "branches_end"))
    status = Map.get(fields, "status", "error")
    branch = first_present([Map.get(fields, "branch"), status_branch(status_short)])
    head = Map.get(fields, "head", "")
    remote_status = parse_int(Map.get(fields, "remote_status", ""))
    canonical_ref = canonical_ref(remote_refs, tracking_refs, base_branch)
    canonical_source = canonical_source(remote_refs, tracking_refs, base_branch)

    checks =
      [
        check(
          status == "ok",
          "repo path is a git repository",
          Map.get(fields, "error", repo_path)
        ),
        check(
          remote_status == 0,
          "canonical remote is reachable",
          remote_failure_detail(remote_status, remote_refs)
        ),
        check(
          Map.has_key?(remote_refs, base_branch),
          "#{base_branch} exists on remote",
          "missing remote #{base_branch}"
        ),
        check(
          promote_branch == "" or Map.has_key?(remote_refs, promote_branch),
          "#{promote_branch} exists on remote",
          "missing remote #{promote_branch}"
        ),
        check(changes == [], "working tree is clean", Enum.join(changes, "; ")),
        check(branch == base_branch, "checked out on #{base_branch}", "current branch #{branch}"),
        check(
          canonical_ref != "" and canonical_ref == head,
          "#{base_branch} matches canonical ref",
          "local #{short(head)} canonical #{short(canonical_ref)} source #{canonical_source}"
        ),
        check(
          single_root_worktree?(worktrees, repo_path),
          "no extra worktrees",
          worktree_detail(worktrees)
        ),
        check(
          expected_local_branches?(branches, base_branch, promote_branch),
          "no unexpected local branches",
          branch_detail(branches, base_branch, promote_branch)
        )
      ]

    %{
      status: status,
      error: Map.get(fields, "error", ""),
      branch: branch,
      head: head,
      upstream: Map.get(fields, "upstream", ""),
      remote: Map.get(fields, "remote", ""),
      remote_url: Map.get(fields, "remote_url", ""),
      remote_status: remote_status,
      remote_output: remote_ref_lines,
      remote_refs: remote_refs,
      tracking_refs: tracking_refs,
      canonical_ref: canonical_ref,
      canonical_source: canonical_source,
      local_ref: head,
      observed_at: observed_at,
      base_branch: base_branch,
      promote_branch: promote_branch,
      status_short: status_short,
      changes: changes,
      worktrees: worktrees,
      branches: branches,
      checks: checks
    }
  end

  defp add_session_checks(instance, project, sessions) do
    stale_sessions = stale_sessions(project, instance.worktrees, sessions)

    instance
    |> Map.put(:orphaned_sessions, stale_sessions)
    |> Map.update!(:checks, fn checks ->
      checks ++
        [
          check(
            stale_sessions == [],
            "no stale repo sessions",
            stale_session_detail(stale_sessions)
          )
        ]
    end)
  end

  defp finalize_instance(instance) do
    instance = Map.put(instance, :observed, observed_state(instance))
    instance = Map.put(instance, :drift, drift_state(instance))
    instance = Map.put(instance, :auth, auth_capabilities(instance))
    instance = Map.put(instance, :auth_status, auth_status(instance))
    instance = Map.put(instance, :reconciliation_status, reconciliation_status(instance))
    instance = Map.put(instance, :trust_status, trust_status(instance))
    instance = Map.put(instance, :confidence, confidence(instance))
    instance = Map.put(instance, :evidence, evidence(instance))
    instance = Map.put(instance, :repo_state, repo_state(instance))

    status =
      if instance.reconciliation_status == "reconciled" and instance.trust_status == "trusted" do
        "ok"
      else
        "fail"
      end

    Map.put(instance, :status, status)
  end

  defp parse_fields(lines) do
    lines
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t", parts: 2) do
        [key, value] when key != "" -> [{key, value}]
        _other -> []
      end
    end)
    |> Map.new()
  end

  defp section(lines, start_marker, end_marker) do
    lines
    |> Enum.drop_while(&(&1 != start_marker))
    |> case do
      [] -> []
      [_start | rest] -> Enum.take_while(rest, &(&1 != end_marker))
    end
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_remote_refs(lines) do
    lines
    |> Enum.flat_map(fn line ->
      case String.split(line, ~r/\s+/, parts: 2, trim: true) do
        [sha, "refs/heads/" <> branch] -> [{branch, sha}]
        _other -> []
      end
    end)
    |> Map.new()
  end

  defp parse_tracking_refs(lines) do
    lines
    |> Enum.flat_map(fn line ->
      case String.split(line, ~r/\s+/, parts: 2, trim: true) do
        [sha, "refs/remotes/" <> remote_branch] ->
          branch =
            remote_branch
            |> String.split("/", parts: 2)
            |> case do
              [_remote, branch] -> branch
              _other -> ""
            end

          if branch == "", do: [], else: [{branch, sha}]

        _other ->
          []
      end
    end)
    |> Map.new()
  end

  defp parse_worktrees(lines) do
    lines
    |> Enum.reduce({[], %{}}, fn line, {worktrees, current} ->
      case String.split(line, " ", parts: 2) do
        ["worktree", path] when map_size(current) > 0 ->
          {[normalize_worktree(current) | worktrees], %{"worktree" => path}}

        ["worktree", path] ->
          {worktrees, %{"worktree" => path}}

        [key, value] ->
          {worktrees, Map.put(current, key, value)}

        _other ->
          {worktrees, current}
      end
    end)
    |> then(fn
      {worktrees, current} when map_size(current) > 0 -> [normalize_worktree(current) | worktrees]
      {worktrees, _current} -> worktrees
    end)
    |> Enum.reverse()
  end

  defp normalize_worktree(worktree) do
    %{
      path: Map.get(worktree, "worktree", ""),
      head: Map.get(worktree, "HEAD", ""),
      branch: Map.get(worktree, "branch", "") |> String.replace_prefix("refs/heads/", "")
    }
  end

  defp parse_branches(lines) do
    Enum.map(lines, fn line ->
      [name, upstream, track, head, subject] =
        line
        |> String.split("\t", parts: 5)
        |> pad(5)

      %{name: name, upstream: upstream, track: track, head: head, subject: subject}
    end)
  end

  defp pad(values, count), do: values ++ List.duplicate("", max(count - length(values), 0))

  defp status_branch_line?(line), do: String.starts_with?(String.trim_leading(line), "## ")

  defp status_branch(lines) do
    lines
    |> Enum.find(&status_branch_line?/1)
    |> case do
      nil ->
        ""

      line ->
        line
        |> String.trim_leading()
        |> String.replace_prefix("## ", "")
        |> String.split("...", parts: 2)
        |> hd()
        |> String.split(" ", parts: 2)
        |> hd()
    end
  end

  defp single_root_worktree?([%{path: path}], repo_path), do: path == repo_path
  defp single_root_worktree?(_worktrees, _repo_path), do: false

  defp expected_local_branches?(branches, base_branch, promote_branch) do
    allowed = [base_branch, promote_branch] |> Enum.reject(&(&1 == "")) |> MapSet.new()

    Enum.all?(branches, fn branch ->
      MapSet.member?(allowed, branch.name)
    end)
  end

  defp canonical_ref(remote_refs, tracking_refs, branch) do
    Map.get(remote_refs, branch) || Map.get(tracking_refs, branch) || ""
  end

  defp canonical_source(remote_refs, tracking_refs, branch) do
    cond do
      Map.has_key?(remote_refs, branch) -> "remote"
      Map.has_key?(tracking_refs, branch) -> "tracking"
      true -> "missing"
    end
  end

  defp stale_sessions(project, worktrees, sessions) when is_list(sessions) do
    known_worktrees = Enum.map(worktrees, & &1.path)

    worktree_root =
      Path.join([project.host.workspace_path, "projects", project.slug, "worktrees"])

    sessions
    |> Enum.filter(&same_host?(&1, project.host.name))
    |> Enum.filter(&repo_session?(&1, project.repo_path, worktree_root))
    |> Enum.filter(&stale_session?(&1, known_worktrees, worktree_root))
    |> Enum.map(&session_summary/1)
  end

  defp stale_sessions(_project, _worktrees, _sessions), do: []

  defp same_host?(session, host_name), do: field(session, :host) in [nil, "", host_name]

  defp repo_session?(session, repo_path, worktree_root) do
    text = [field(session, :current_path), field(session, :command), field(session, :target)]

    Enum.any?(text, &contains_path?(&1, repo_path)) or
      Enum.any?(text, &contains_path?(&1, worktree_root))
  end

  defp stale_session?(session, known_worktrees, worktree_root) do
    path = field(session, :current_path)

    cond do
      String.contains?(path, "(deleted)") ->
        true

      contains_path?(path, worktree_root) ->
        Enum.all?(known_worktrees, fn worktree -> !String.starts_with?(path, worktree) end)

      true ->
        false
    end
  end

  defp session_summary(session) do
    %{
      ref: field(session, :ref),
      type: field(session, :type),
      kind: field(session, :kind),
      current_path: field(session, :current_path),
      command: field(session, :command)
    }
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key)) || ""
  end

  defp contains_path?("", _path), do: false
  defp contains_path?(_text, ""), do: false
  defp contains_path?(text, path), do: String.contains?(to_string(text), path)

  defp check(true, name, detail), do: ok(name, detail)
  defp check(false, name, detail), do: fail(name, detail)

  defp ok(name, detail), do: %{name: name, status: :ok, detail: compact(detail)}
  defp fail(name, detail), do: %{name: name, status: :fail, detail: compact(detail)}

  defp remote_failure_detail(0, _remote_refs), do: "remote reachable"

  defp remote_failure_detail(status, _remote_refs) when is_integer(status),
    do: "git ls-remote exited #{status}"

  defp remote_failure_detail(_status, _remote_refs), do: "git ls-remote did not report status"

  defp worktree_detail(worktrees) do
    worktrees
    |> Enum.map(& &1.path)
    |> Enum.join("; ")
  end

  defp branch_detail(branches, base_branch, promote_branch) do
    allowed = [base_branch, promote_branch] |> Enum.reject(&(&1 == "")) |> MapSet.new()

    branches
    |> Enum.reject(&MapSet.member?(allowed, &1.name))
    |> Enum.map(& &1.name)
    |> Enum.join("; ")
  end

  defp stale_session_detail(sessions) do
    sessions
    |> Enum.map(fn session ->
      [session.ref, session.current_path, session.command]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")
    end)
    |> Enum.join("; ")
  end

  defp observed_state(instance) do
    %{
      observed_at: Map.get(instance, :observed_at),
      canonical_ref: Map.get(instance, :canonical_ref, ""),
      canonical_source: Map.get(instance, :canonical_source, "missing"),
      local_ref: Map.get(instance, :local_ref, ""),
      branch: Map.get(instance, :branch, ""),
      dirty: Map.get(instance, :changes, []) != [],
      worktree_count: length(Map.get(instance, :worktrees, [])),
      orphaned_sessions: Map.get(instance, :orphaned_sessions, [])
    }
  end

  defp drift_state(instance) do
    base_branch = Map.get(instance, :base_branch, "develop")
    promote_branch = Map.get(instance, :promote_branch, "master")
    canonical_ref = Map.get(instance, :canonical_ref, "")
    local_ref = Map.get(instance, :local_ref, "")
    worktrees = Map.get(instance, :worktrees, [])
    branches = Map.get(instance, :branches, [])
    base_tracking = branch_track(branches, base_branch)

    types =
      []
      |> maybe_add_drift(Map.get(instance, :status) != "ok", "unknown")
      |> maybe_add_drift(Map.get(instance, :changes, []) != [], "dirty")
      |> maybe_add_drift(Map.get(instance, :branch) != base_branch, "wrong_branch")
      |> maybe_add_drift(canonical_ref == "", "unknown")
      |> maybe_add_drift(
        canonical_ref != "" and local_ref != canonical_ref,
        ref_drift_type(base_tracking)
      )
      |> maybe_add_drift(
        !single_root_worktree?(worktrees, Map.get(instance, :repo_path, "")),
        "extra_worktrees"
      )
      |> maybe_add_drift(
        !expected_local_branches?(branches, base_branch, promote_branch),
        "unexpected_branches"
      )
      |> maybe_add_drift(Map.get(instance, :orphaned_sessions, []) != [], "orphaned")
      |> Enum.uniq()

    %{status: drift_status(types), present: types != [], types: types, reasons: types}
  end

  defp auth_capabilities(%{remote_status: 0}) do
    %{
      remote_reachable: "ok",
      auth_valid: "ok",
      fetch_allowed: "ok",
      push_allowed: "unknown",
      api_allowed: "unknown",
      detail: "remote fetch check passed"
    }
  end

  defp auth_capabilities(instance) do
    remote_output = Map.get(instance, :remote_output, [])
    auth_failed? = auth_failure?(remote_output)

    %{
      remote_reachable: if(auth_failed?, do: "ok", else: "unknown"),
      auth_valid: if(auth_failed?, do: "failed", else: "unknown"),
      fetch_allowed: "failed",
      push_allowed: "unknown",
      api_allowed: "unknown",
      detail: remote_error_detail(remote_output, Map.get(instance, :remote_status))
    }
  end

  defp auth_status(%{auth: %{fetch_allowed: "ok"}}), do: "ok"

  defp auth_status(instance) do
    if Map.get(instance, :canonical_source) == "tracking" and
         get_in(instance, [:auth, :auth_valid]) == "failed" do
      "degraded"
    else
      "untrusted"
    end
  end

  defp reconciliation_status(instance) do
    cond do
      Map.get(instance, :status) != "ok" or Map.get(instance, :canonical_ref, "") == "" ->
        "unknown"

      instance.drift.present ->
        "drifted"

      true ->
        "reconciled"
    end
  end

  defp trust_status(%{reconciliation_status: "reconciled", auth_status: "ok"}), do: "trusted"

  defp trust_status(%{reconciliation_status: "reconciled", auth_status: "degraded"}) do
    "degraded"
  end

  defp trust_status(_instance), do: "untrusted"

  defp confidence(%{trust_status: "trusted", reconciliation_status: "reconciled"}), do: "high"
  defp confidence(%{trust_status: "degraded", reconciliation_status: "reconciled"}), do: "partial"
  defp confidence(%{reconciliation_status: "unknown"}), do: "unknown"
  defp confidence(_instance), do: "low"

  defp evidence(instance) do
    observed_at = Map.get(instance, :observed_at)

    %{
      observation: %{
        observed_at: observed_at,
        host: Map.get(instance, :host, ""),
        repo_path: Map.get(instance, :repo_path, "")
      },
      canonical_ref: %{
        source: Map.get(instance, :canonical_source, "missing"),
        observed_at: observed_at,
        branch: Map.get(instance, :base_branch, ""),
        value: Map.get(instance, :canonical_ref, "")
      },
      local_ref: %{
        source: "git rev-parse --verify HEAD",
        observed_at: observed_at,
        branch: Map.get(instance, :branch, ""),
        value: Map.get(instance, :local_ref, "")
      },
      remote_auth: Map.merge(instance.auth, %{source: "git ls-remote", observed_at: observed_at}),
      remote_refs: %{
        source: "git ls-remote --heads",
        observed_at: observed_at,
        status: Map.get(instance, :remote_status),
        refs: Map.get(instance, :remote_refs, %{}),
        output: Map.get(instance, :remote_output, [])
      },
      tracking_refs: %{
        source: "refs/remotes",
        observed_at: observed_at,
        refs: Map.get(instance, :tracking_refs, %{})
      },
      drift: instance.drift
    }
  end

  defp maybe_add_drift(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_add_drift(reasons, false, _reason), do: reasons

  defp repo_state(instance) do
    Map.merge(instance.observed, %{
      drift: instance.drift,
      auth_status: instance.auth_status,
      auth: instance.auth,
      reconciliation_status: instance.reconciliation_status,
      trust_status: instance.trust_status,
      confidence: instance.confidence
    })
  end

  defp branch_track(branches, branch_name) do
    branches
    |> Enum.find(&(&1.name == branch_name))
    |> case do
      nil -> ""
      branch -> branch.track
    end
  end

  defp ref_drift_type(track) do
    track = String.downcase(to_string(track))
    ahead? = String.contains?(track, "ahead")
    behind? = String.contains?(track, "behind")

    cond do
      ahead? and behind? -> "diverged"
      ahead? -> "ahead"
      behind? -> "behind"
      true -> "ref_mismatch"
    end
  end

  defp drift_status([]), do: "none"

  defp drift_status(types) do
    cond do
      "unknown" in types -> "unknown"
      "diverged" in types -> "diverged"
      "dirty" in types -> "dirty"
      "orphaned" in types -> "orphaned"
      "ahead" in types -> "ahead"
      "behind" in types -> "behind"
      true -> "drifted"
    end
  end

  defp auth_failure?(remote_output) do
    text = remote_output |> Enum.join("\n") |> String.downcase()

    Enum.any?(
      [
        "authentication failed",
        "invalid username or token",
        "permission denied",
        "could not read username",
        "repository not found"
      ],
      &String.contains?(text, &1)
    )
  end

  defp remote_error_detail([], nil), do: "git ls-remote did not report status"
  defp remote_error_detail([], status), do: "git ls-remote exited #{status}"

  defp remote_error_detail(remote_output, _status) do
    remote_output
    |> Enum.join("; ")
    |> compact()
  end

  defp summary(instances) do
    %{
      total: length(instances),
      ok: Enum.count(instances, &(&1.status == "ok")),
      failed: Enum.count(instances, &(&1.status != "ok")),
      reconciled: Enum.count(instances, &(&1.reconciliation_status == "reconciled")),
      trusted: Enum.count(instances, &(&1.trust_status == "trusted")),
      degraded: Enum.count(instances, &(&1.trust_status == "degraded")),
      untrusted: Enum.count(instances, &(&1.trust_status == "untrusted")),
      high_confidence: Enum.count(instances, &(&1.confidence == "high")),
      partial_confidence: Enum.count(instances, &(&1.confidence == "partial")),
      low_confidence: Enum.count(instances, &(&1.confidence == "low")),
      unknown_confidence: Enum.count(instances, &(&1.confidence == "unknown"))
    }
  end

  defp registry_warnings(_project_name, [_project | _rest]), do: []
  defp registry_warnings(project_name, []), do: ["project #{project_name} is not registered"]

  defp parse_int(""), do: nil

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp first_present(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end) || ""
  end

  defp short(nil), do: ""
  defp short(value) when byte_size(value) <= 12, do: value
  defp short(value), do: binary_part(value, 0, 12)

  defp compact(nil), do: ""

  defp compact(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/\s*\R\s*/, "; ")
    |> truncate(240)
  end

  defp truncate(value, max_size) when byte_size(value) <= max_size, do: value
  defp truncate(value, max_size), do: binary_part(value, 0, max_size) <> "..."
end
