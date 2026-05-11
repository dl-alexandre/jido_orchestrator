defmodule JX.RuntimeEnvironments do
  @moduledoc """
  Durable workspace runtime lifecycle orchestration.

  JX owns placement, worktree lifecycle evidence, and assignment routing. DevIDE
  remains authoritative for executable safe actions; this module never accepts
  argv, shell fragments, or safe-action definitions from callers.
  """

  import Ecto.Query

  alias JX.DelegatedExecution
  alias JX.OperationalEvents
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Projects
  alias JX.Repo
  alias JX.RuntimeEnvironments.Environment
  alias JX.SafeActions
  alias JX.SSH
  alias JX.Shell

  @default_ttl_seconds 24 * 60 * 60
  @runtime_capability "runtime-environment:v1"
  @safe_action_capability "safe_action:rerun_devide_command"

  def list(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    _ = expire(now: now)

    Environment
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_workspace(Keyword.get(opts, :workspace_id))
    |> maybe_filter_runner(Keyword.get(opts, :runner_id))
    |> order_by([env],
      asc:
        fragment(
          "case ? when 'ready' then 0 when 'assigned' then 1 when 'provisioning' then 2 when 'planned' then 3 when 'failed' then 4 when 'expired' then 5 else 6 end",
          env.status
        ),
      desc: env.updated_at
    )
    |> limit(^Keyword.get(opts, :limit, 50))
    |> Repo.all()
    |> Enum.map(&summary/1)
  end

  def get(runtime_id), do: Repo.get_by(Environment, runtime_id: clean(runtime_id))

  def provision_for_action(action_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, detail} <- SafeActions.show(clean(action_id)),
         %OrchestrationAction{} = action <- detail.action,
         :ok <- ensure_action_planned(action),
         {:ok, project} <- fetch_project(opts),
         attrs <- runtime_attrs(action, detail.payload, project, opts, now),
         {:ok, env} <- upsert_runtime(attrs),
         {:ok, env} <- mark(env, "provisioning", now, "runtime.provisioning"),
         {:ok, env} <- run_provisioning(env, project, opts, now) do
      {:ok, env}
    end
  end

  def assign_action(runtime_id, action_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with %Environment{} = env <- get(runtime_id),
         :ok <- ensure_runtime_ready(env, now),
         {:ok, detail} <- SafeActions.show(clean(action_id)),
         %OrchestrationAction{} = action <- detail.action,
         :ok <- ensure_action_planned(action),
         {:ok, assignment} <-
           DelegatedExecution.create_assignment(action.action_id,
             now: now,
             ttl_seconds: Keyword.get(opts, :ttl_seconds, @default_ttl_seconds),
             created_by: Keyword.get(opts, :created_by, "operator"),
             runner_requirements: routing_requirements(env),
             runtime: runtime_payload(env)
           ),
         {:ok, env, assignment} <- assign_runtime(env, assignment, opts, now) do
      {:ok, %{runtime: env, assignment: assignment}}
    else
      nil -> {:error, :runtime_not_found}
      {:error, _reason} = error -> error
    end
  end

  def release(runtime_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with %Environment{} = env <- get(runtime_id),
         {:ok, env} <-
           env
           |> Environment.changeset(%{
             status: "released",
             assignment_id: "",
             released_at: now,
             last_error: ""
           })
           |> Repo.update() do
      _ = record(env, "runtime.released", now)
      {:ok, env}
    else
      nil -> {:error, :runtime_not_found}
      {:error, _reason} = error -> error
    end
  end

  def expire(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Environment
    |> where([env], env.status in ^Environment.active_statuses())
    |> where([env], not is_nil(env.expires_at) and env.expires_at <= ^now)
    |> Repo.all()
    |> Enum.map(fn env ->
      {:ok, expired} =
        env
        |> Environment.changeset(%{status: "expired", last_error: "runtime lease expired"})
        |> Repo.update()

      _ = record(expired, "runtime.expired", now, severity: "warning")
      expired
    end)
  end

  def summary(%Environment{} = env) do
    %{
      runtime_id: env.runtime_id,
      workspace_id: env.workspace_id,
      action_id: env.action_id,
      assignment_id: env.assignment_id,
      runner_id: env.runner_id,
      project_name: env.project_name,
      host_name: env.host_name,
      repo_path: env.repo_path,
      worktree_path: env.worktree_path,
      branch: env.branch,
      status: env.status,
      capabilities: decode_json_list(env.capabilities),
      tools: decode_json_list(env.tools),
      os: env.os,
      branch_isolation: env.branch_isolation,
      concurrency_limit: env.concurrency_limit,
      reusable: env.reusable,
      correlation_id: env.correlation_id,
      metadata: decode_json(env.metadata, %{}),
      last_error: env.last_error,
      provisioned_at: env.provisioned_at,
      assigned_at: env.assigned_at,
      released_at: env.released_at,
      expires_at: env.expires_at,
      next: "jx runtimes show #{env.runtime_id}"
    }
  end

  def routing_requirements(%Environment{} = env) do
    %{
      "host" => env.host_name,
      "os" => env.os,
      "repo" => env.repo_path,
      "branch_isolation" => env.branch_isolation,
      "runtime_id" => env.runtime_id,
      "runtime_path" => env.worktree_path,
      "tools" => decode_json_list(env.tools)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  def runtime_payload(%Environment{} = env) do
    %{
      runtime_id: env.runtime_id,
      workspace_id: env.workspace_id,
      host_name: env.host_name,
      repo_path: env.repo_path,
      worktree_path: env.worktree_path,
      branch: env.branch,
      status: env.status,
      capabilities: decode_json_list(env.capabilities),
      tools: decode_json_list(env.tools),
      os: env.os,
      branch_isolation: env.branch_isolation,
      concurrency_limit: env.concurrency_limit,
      reusable: env.reusable
    }
  end

  defp runtime_attrs(%OrchestrationAction{} = action, payload, project, opts, now) do
    workspace_id = text_field(payload, "workspace_id")
    runtime_id = runtime_id(action.action_id, project, opts)
    root = Path.join([project.host.workspace_path, "projects", project.slug])
    worktree_path = Keyword.get(opts, :worktree_path) || Path.join([root, "runtimes", runtime_id])
    runtime_dir = Path.join([root, ".jx", "runtimes", runtime_id])
    branch = Keyword.get(opts, :branch) || "jx/runtime/#{runtime_id}"

    %{
      runtime_id: runtime_id,
      workspace_id: workspace_id,
      action_id: action.action_id,
      runner_id: clean(Keyword.get(opts, :runner_id, "")),
      project_name: project.name,
      host_name: project.host.name,
      repo_path: project.repo_path,
      worktree_path: worktree_path,
      branch: branch,
      status: "planned",
      capabilities: encode_json(runtime_capabilities(opts)),
      tools:
        encode_json(Keyword.get(opts, :tools, Keyword.get(opts, :tool, [])) |> string_list()),
      os: clean(Keyword.get(opts, :os, "")),
      branch_isolation: clean(Keyword.get(opts, :branch_isolation, "worktree")),
      concurrency_limit: Keyword.get(opts, :concurrency_limit, 1),
      reusable: Keyword.get(opts, :reusable, true),
      correlation_id: clean(Keyword.get(opts, :correlation_id, action_correlation_id(action))),
      metadata:
        encode_json(%{
          runtime_dir: runtime_dir,
          created_by: Keyword.get(opts, :created_by, "operator"),
          authority: "jx_runtime_lifecycle_only",
          execution_authority: "devide_safe_action_registry"
        }),
      expires_at:
        DateTime.add(now, Keyword.get(opts, :ttl_seconds, @default_ttl_seconds), :second)
    }
  end

  defp upsert_runtime(attrs) do
    case Repo.get_by(Environment, runtime_id: attrs.runtime_id) do
      nil -> %Environment{}
      env -> env
    end
    |> Environment.changeset(attrs)
    |> Repo.insert_or_update()
    |> case do
      {:ok, env} ->
        _ = record(env, "runtime.planned", DateTime.utc_now())
        {:ok, env}

      {:error, _reason} = error ->
        error
    end
  end

  defp mark(%Environment{} = env, status, now, kind) do
    env
    |> Environment.changeset(%{status: status, last_error: ""})
    |> Repo.update()
    |> case do
      {:ok, env} ->
        _ = record(env, kind, now)
        {:ok, env}

      {:error, _reason} = error ->
        error
    end
  end

  defp run_provisioning(%Environment{} = env, project, opts, now) do
    script = provisioning_script(env)

    runner =
      Keyword.get(opts, :runner, fn host, script -> SSH.adapter(host).run(host, script) end)

    case runner.(project.host, script) do
      {:ok, output} ->
        env
        |> Environment.changeset(%{
          status: "ready",
          provisioned_at: now,
          last_error: "",
          metadata: merge_metadata(env, %{"provision_output" => String.slice(output, 0, 4_000)})
        })
        |> Repo.update()
        |> case do
          {:ok, env} ->
            _ = record(env, "runtime.ready", now, payload: %{"provision_output" => output})
            {:ok, env}

          {:error, _reason} = error ->
            error
        end

      {:error, reason} ->
        env
        |> Environment.changeset(%{status: "failed", last_error: inspect(reason)})
        |> Repo.update()
        |> case do
          {:ok, env} ->
            _ =
              record(env, "runtime.failed", now,
                severity: "warning",
                failure_class: "provision_failed"
              )

            {:error, {:provision_failed, reason, env}}

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp assign_runtime(%Environment{} = env, assignment, opts, now) do
    runner_id = clean(Keyword.get(opts, :runner_id, env.runner_id))

    with {:ok, assignment} <- maybe_claim_assignment(env, assignment, runner_id, opts, now),
         {:ok, env} <-
           env
           |> Environment.changeset(%{
             status: "assigned",
             assignment_id: assignment.assignment_id,
             runner_id: runner_id,
             assigned_at: now,
             last_error: ""
           })
           |> Repo.update() do
      _ =
        record(env, "runtime.assigned", now,
          payload: %{"assignment_id" => assignment.assignment_id, "runner_id" => runner_id}
        )

      {:ok, env, assignment}
    end
  end

  defp maybe_claim_assignment(_env, assignment, "", _opts, _now), do: {:ok, assignment}

  defp maybe_claim_assignment(env, assignment, runner_id, opts, now) do
    DelegatedExecution.claim_runner_assignment(assignment.assignment_id, runner_id,
      session_id: Keyword.get(opts, :session_id, "rt-#{env.runtime_id}"),
      tmux_session_name: Keyword.get(opts, :tmux_session_name, "jx_#{env.runtime_id}"),
      log_path: Keyword.get(opts, :log_path, Path.join([env.worktree_path, ".jx-runtime.log"])),
      now: now,
      ttl_seconds: Keyword.get(opts, :claim_ttl_seconds, @default_ttl_seconds),
      created_by: Keyword.get(opts, :created_by, "operator")
    )
    |> case do
      {:ok, %{assignment: claimed}} -> {:ok, claimed}
      {:ok, claimed} -> {:ok, claimed}
      {:error, _reason} = error -> error
    end
  end

  defp provisioning_script(%Environment{} = env) do
    metadata = decode_json(env.metadata, %{})
    runtime_dir = Map.fetch!(metadata, "runtime_dir")
    runtime_json = summary(env) |> Jason.encode!() |> Shell.quote()

    """
    set -eu
    repo=#{Shell.quote(env.repo_path)}
    runtime=#{Shell.quote(env.worktree_path)}
    runtime_dir=#{Shell.quote(runtime_dir)}
    branch=#{Shell.quote(env.branch)}

    if [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; then
      echo "repo path is not a git checkout: $repo" >&2
      exit 1
    fi

    mkdir -p "$(dirname "$runtime")" "$runtime_dir/artifacts"
    printf %s #{runtime_json} > "$runtime_dir/runtime.json"

    if [ ! -d "$runtime/.git" ] && [ ! -f "$runtime/.git" ]; then
      if [ -e "$runtime" ] && [ -n "$(find "$runtime" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]; then
        echo "runtime path exists and is not empty: $runtime" >&2
        exit 1
      fi
      git -C "$repo" worktree add -B "$branch" "$runtime" HEAD
    fi
    """
  end

  defp record(%Environment{} = env, kind, now, opts \\ []) do
    payload =
      env
      |> summary()
      |> Map.merge(Keyword.get(opts, :payload, %{}))
      |> Map.put(:failure_class, Keyword.get(opts, :failure_class, ""))

    OperationalEvents.record_once(%{
      event_id: "runtime:#{kind}:#{env.runtime_id}:#{env.status}",
      source: "runtime",
      kind: kind,
      entity_type: "runtime_environment",
      entity_id: env.runtime_id,
      workspace_id: env.workspace_id,
      action_id: env.action_id,
      owner: env.runner_id,
      correlation_id: env.correlation_id,
      severity: Keyword.get(opts, :severity, "notice"),
      summary: "runtime #{env.runtime_id} #{env.status}",
      payload: Map.put(payload, :recorded_at, now)
    })
  end

  defp ensure_action_planned(%OrchestrationAction{status: status})
       when status in ["planned", "queued"],
       do: :ok

  defp ensure_action_planned(%OrchestrationAction{status: status}),
    do: {:error, {:action_not_assignable, status}}

  defp ensure_runtime_ready(%Environment{status: "ready"}, _now), do: :ok
  defp ensure_runtime_ready(%Environment{status: "assigned", reusable: true}, _now), do: :ok

  defp ensure_runtime_ready(%Environment{status: status}, _now),
    do: {:error, {:runtime_not_ready, status}}

  defp fetch_project(opts) do
    project_name = clean(Keyword.get(opts, :project) || Keyword.get(opts, :project_name))
    host_name = clean(Keyword.get(opts, :host) || Keyword.get(opts, :host_name))

    case {project_name, host_name} do
      {"", _host} ->
        {:error, :project_required}

      {project_name, ""} ->
        case Projects.get_project_by_name(project_name) do
          nil -> {:error, :project_not_found}
          project -> {:ok, project}
        end

      {project_name, host_name} ->
        case Projects.get_project_by_name(project_name, host_name) do
          nil -> {:error, :project_not_found}
          project -> {:ok, project}
        end
    end
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, "all"), do: query

  defp maybe_filter_status(query, "active"),
    do: where(query, [env], env.status in ^Environment.active_statuses())

  defp maybe_filter_status(query, status), do: where(query, [env], env.status == ^status)

  defp maybe_filter_workspace(query, nil), do: query

  defp maybe_filter_workspace(query, workspace_id),
    do: where(query, [env], env.workspace_id == ^workspace_id)

  defp maybe_filter_runner(query, nil), do: query
  defp maybe_filter_runner(query, runner_id), do: where(query, [env], env.runner_id == ^runner_id)

  defp runtime_id(action_id, project, opts) do
    Keyword.get(opts, :runtime_id) ||
      "rt-" <>
        (:crypto.hash(:sha256, [
           action_id,
           <<0>>,
           project.name,
           <<0>>,
           project.host.name,
           <<0>>,
           clean(Keyword.get(opts, :runner_id, ""))
         ])
         |> Base.encode16(case: :lower)
         |> binary_part(0, 12))
  end

  defp runtime_capabilities(opts) do
    ([@runtime_capability, @safe_action_capability] ++
       string_list(Keyword.get(opts, :capabilities, Keyword.get(opts, :capability, []))))
    |> Enum.uniq()
  end

  defp action_correlation_id(%OrchestrationAction{payload: payload}) do
    payload
    |> decode_json(%{})
    |> text_field("correlation_id")
    |> case do
      nil -> OperationalEvents.correlation_id()
      value -> value
    end
  end

  defp merge_metadata(%Environment{} = env, extra) do
    env.metadata
    |> decode_json(%{})
    |> Map.merge(extra)
    |> encode_json()
  end

  defp clean(nil), do: ""
  defp clean(value), do: value |> to_string() |> String.trim()

  defp string_list(value) when is_list(value) do
    value
    |> Enum.map(&clean/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp string_list(value) when is_binary(value), do: string_list([value])
  defp string_list(_value), do: []

  defp encode_json(value), do: Jason.encode!(value)

  defp decode_json(text, fallback) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> fallback
    end
  end

  defp decode_json(_text, fallback), do: fallback

  defp decode_json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, values} when is_list(values) -> Enum.map(values, &to_string/1)
      _other -> []
    end
  end

  defp decode_json_list(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp decode_json_list(_value), do: []

  defp text_field(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when value in [nil, ""] -> nil
      value -> to_string(value)
    end
  end

  defp text_field(_map, _key), do: nil
end
