defmodule JX.ResourceOwnerships do
  @moduledoc """
  Registry for resources created by JX-controlled execution paths.

  The registry is intentionally conservative: cleanup discovery starts from
  durable ownership records, then enriches them with live host state where that
  can be observed without mutating anything.
  """

  import Ecto.Query

  alias JX.Repo
  alias JX.ResourceOwnerships.Resource
  alias JX.Shell
  alias JX.Tmux

  @active_states ~w(created live stale unknown)
  @stale_after_seconds 86_400

  def register(attrs, opts \\ []) when is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    attrs = normalize_attrs(attrs, now)

    %Resource{}
    |> Resource.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :owner_project,
           :owner_type,
           :assignment_id,
           :execution_id,
           :resource_type,
           :resource_name,
           :resource_path,
           :tmux_server,
           :cleanup_policy,
           :state,
           :reason,
           :metadata,
           :ended_at,
           :updated_at
         ]},
      conflict_target: [:resource_id]
    )
  end

  def register_tmux_session(attrs, opts \\ []) do
    attrs
    |> Map.merge(%{
      resource_type: "tmux_session",
      cleanup_policy: Map.get(attrs, :cleanup_policy, "kill_tmux_session"),
      state: Map.get(attrs, :state, "created")
    })
    |> register(opts)
  end

  def register_temp_path(attrs, opts \\ []) do
    attrs
    |> Map.merge(%{
      resource_type: Map.get(attrs, :resource_type, "temp_path"),
      cleanup_policy: Map.get(attrs, :cleanup_policy, "rm_rf"),
      state: Map.get(attrs, :state, "created")
    })
    |> register(opts)
  end

  def mark_exempt(attrs, opts \\ []) do
    attrs
    |> Map.merge(%{cleanup_policy: "exempt", state: "exempt"})
    |> register(opts)
  end

  def list(opts \\ []) do
    Resource
    |> maybe_filter_owner_project(Keyword.get(opts, :owner_project))
    |> maybe_filter_state(Keyword.get(opts, :state))
    |> maybe_filter_type(Keyword.get(opts, :resource_type))
    |> order_by([resource], desc: resource.created_at, desc: resource.id)
    |> limit(^Keyword.get(opts, :limit, 200))
    |> Repo.all()
  end

  def cleanup_dry_run(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    resources = list(Keyword.put_new(opts, :state, "active"))
    tmux_inventory = tmux_inventory(resources)

    {:ok,
     %{
       generated_at: now,
       apply_available: false,
       resources:
         Enum.map(resources, fn resource ->
           cleanup_item(resource, tmux_inventory, now)
         end)
     }}
  end

  def cleanup_apply(_opts \\ []), do: {:error, :cleanup_apply_not_implemented}

  def ownership_audit(opts \\ []) do
    {:ok,
     %{
       generated_at: Keyword.get(opts, :now, DateTime.utc_now()),
       registered_long_lived:
         list(Keyword.merge(opts, state: Keyword.get(opts, :state, "active")))
         |> Enum.map(&audit_resource/1),
       exempt_creator_paths: known_exemptions(),
       unknown_unclassified: [],
       unknown_detection:
         "not_detectable_without_guessing; cleanup starts from registry records only"
     }}
  end

  def known_exemptions do
    [
      %{
        creator: "JX.HostDoctor.tmux_checks/1",
        resource_type: "tmux_session",
        reason: "short-lived probe uses trap plus explicit kill-session inline",
        cleanup_policy: "self_cleaning_probe"
      },
      %{
        creator: "JX.HostDoctor.workspace_checks/1",
        resource_type: "temp_path",
        reason: "short-lived filesystem probe removes the created temp file inline",
        cleanup_policy: "self_cleaning_probe"
      },
      %{
        creator: "JX.PaneTransport.probe/2",
        resource_type: "command_probe",
        reason:
          "read-only command probe executes in an existing pane and creates no long-lived resource",
        cleanup_policy: "no_resource_created"
      }
    ]
  end

  defp cleanup_item(%Resource{} = resource, tmux_inventory, now) do
    status = resource_status(resource, tmux_inventory, now)

    %{
      resource_id: resource.resource_id,
      owner_type: resource.owner_type,
      owner_project: resource.owner_project,
      assignment_id: resource.assignment_id,
      execution_id: resource.execution_id,
      resource_type: resource.resource_type,
      resource: resource_label(resource),
      cleanup_policy: resource.cleanup_policy,
      state: status.state,
      live_status: status.live_status,
      attached: status.attached,
      stale: status.stale,
      why_owned: why_owned(resource),
      cleanup_command: cleanup_command(resource),
      created_at: resource.created_at,
      reason: resource.reason
    }
  end

  defp audit_resource(%Resource{} = resource) do
    %{
      resource_id: resource.resource_id,
      owner_type: resource.owner_type,
      owner_project: resource.owner_project,
      assignment_id: resource.assignment_id,
      execution_id: resource.execution_id,
      resource_type: resource.resource_type,
      resource: resource_label(resource),
      cleanup_policy: resource.cleanup_policy,
      state: resource.state,
      created_at: resource.created_at,
      reason: resource.reason
    }
  end

  defp resource_status(%Resource{cleanup_policy: "exempt"}, _tmux_inventory, _now) do
    %{state: "exempt", live_status: "exempt", attached: nil, stale: false}
  end

  defp resource_status(%Resource{resource_type: "tmux_session"} = resource, tmux_inventory, now) do
    key = {normalize_tmux_server(resource.tmux_server), resource.resource_name}

    case Map.get(tmux_inventory, key) do
      nil ->
        %{state: "missing", live_status: "missing", attached: false, stale: stale?(resource, now)}

      session ->
        attached = session.attached > 0

        %{
          state: if(attached, do: "live", else: stale_state(resource, now)),
          live_status: if(attached, do: "attached", else: "detached"),
          attached: attached,
          stale: stale?(resource, now)
        }
    end
  end

  defp resource_status(%Resource{resource_path: path} = resource, _tmux_inventory, now)
       when is_binary(path) and path != "" do
    exists? = File.exists?(path)

    %{
      state: if(exists?, do: stale_state(resource, now), else: "missing"),
      live_status: if(exists?, do: "exists", else: "missing"),
      attached: nil,
      stale: stale?(resource, now)
    }
  end

  defp resource_status(%Resource{} = resource, _tmux_inventory, now) do
    %{
      state: resource.state || "unknown",
      live_status: "unknown",
      attached: nil,
      stale: stale?(resource, now)
    }
  end

  defp stale_state(resource, now), do: if(stale?(resource, now), do: "stale", else: "live")

  defp stale?(%Resource{created_at: nil}, _now), do: false

  defp stale?(%Resource{created_at: created_at}, now) do
    DateTime.diff(now, created_at, :second) >= @stale_after_seconds
  end

  defp why_owned(resource) do
    ids =
      [
        id_reason("assignment", resource.assignment_id),
        id_reason("execution", resource.execution_id)
      ]
      |> Enum.reject(&(&1 == ""))

    base = "registered owner_project=#{resource.owner_project}"

    case ids do
      [] -> base
      ids -> base <> " " <> Enum.join(ids, " ")
    end
  end

  defp id_reason(_label, nil), do: ""
  defp id_reason(_label, ""), do: ""
  defp id_reason(label, value), do: "#{label}=#{value}"

  defp cleanup_command(%Resource{cleanup_policy: "kill_tmux_session"} = resource) do
    server = normalize_tmux_server(resource.tmux_server)

    "#{Tmux.command(server)} kill-session -t #{Shell.quote(resource.resource_name)}"
  end

  defp cleanup_command(%Resource{cleanup_policy: "rm_rf", resource_path: path})
       when is_binary(path) and path != "" do
    "rm -rf " <> Shell.quote(path)
  end

  defp cleanup_command(%Resource{cleanup_policy: "exempt"}), do: "exempt"
  defp cleanup_command(%Resource{}), do: "manual"

  defp resource_label(%Resource{resource_type: "tmux_session"} = resource) do
    "#{normalize_tmux_server(resource.tmux_server)}/#{resource.resource_name}"
  end

  defp resource_label(%Resource{resource_path: path}) when is_binary(path) and path != "",
    do: path

  defp resource_label(%Resource{resource_name: name}), do: name

  defp tmux_inventory(resources) do
    resources
    |> Enum.filter(&(&1.resource_type == "tmux_session"))
    |> Enum.map(&normalize_tmux_server(&1.tmux_server))
    |> Enum.uniq()
    |> Enum.flat_map(&tmux_sessions/1)
    |> Map.new(fn session -> {{session.server, session.name}, session} end)
  end

  defp tmux_sessions(server) do
    args =
      Tmux.args(
        [
          "list-sessions",
          "-F",
          "#{server}\t#{tmux_format("session_name")}\t#{tmux_format("session_attached")}\t#{tmux_format("session_created")}"
        ],
        server
      )

    case System.cmd("tmux", args, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_tmux_session/1)

      _error ->
        []
    end
  end

  defp parse_tmux_session(line) do
    case String.split(line, "\t", parts: 4) do
      [server, name, attached, created] ->
        [
          %{
            server: server,
            name: name,
            attached: parse_int(attached),
            created: parse_int(created)
          }
        ]

      _other ->
        []
    end
  end

  defp tmux_format(name), do: "\#{" <> name <> "}"

  defp normalize_attrs(attrs, now) do
    attrs = for {key, value} <- attrs, into: %{}, do: {key, clean(value)}
    resource_type = Map.fetch!(attrs, :resource_type)
    resource_name = Map.fetch!(attrs, :resource_name)
    resource_path = Map.get(attrs, :resource_path, "")

    %{
      resource_id:
        Map.get(attrs, :resource_id) ||
          resource_id(
            resource_type,
            resource_name,
            resource_path,
            Map.get(attrs, :tmux_server, "")
          ),
      owner_type: Map.get(attrs, :owner_type, "project"),
      owner_project: Map.fetch!(attrs, :owner_project),
      assignment_id: Map.get(attrs, :assignment_id, ""),
      execution_id: Map.get(attrs, :execution_id, ""),
      resource_type: resource_type,
      resource_name: resource_name,
      resource_path: resource_path,
      tmux_server: Map.get(attrs, :tmux_server, ""),
      cleanup_policy: Map.fetch!(attrs, :cleanup_policy),
      state: Map.get(attrs, :state, "created"),
      reason: Map.get(attrs, :reason, ""),
      metadata: Map.get(attrs, :metadata, "{}"),
      created_at: Map.get(attrs, :created_at, now),
      ended_at: Map.get(attrs, :ended_at)
    }
  end

  defp resource_id(resource_type, resource_name, resource_path, tmux_server) do
    :crypto.hash(
      :sha256,
      Enum.join([resource_type, resource_name, resource_path, tmux_server], "\0")
    )
    |> Base.encode16(case: :lower)
  end

  defp maybe_filter_owner_project(query, nil), do: query
  defp maybe_filter_owner_project(query, ""), do: query

  defp maybe_filter_owner_project(query, owner_project),
    do: where(query, [resource], resource.owner_project == ^owner_project)

  defp maybe_filter_type(query, nil), do: query
  defp maybe_filter_type(query, ""), do: query

  defp maybe_filter_type(query, resource_type),
    do: where(query, [resource], resource.resource_type == ^resource_type)

  defp maybe_filter_state(query, "active"),
    do: where(query, [resource], resource.state in ^@active_states)

  defp maybe_filter_state(query, nil), do: query
  defp maybe_filter_state(query, ""), do: query
  defp maybe_filter_state(query, state), do: where(query, [resource], resource.state == ^state)

  defp normalize_tmux_server(nil), do: Tmux.managed_server()
  defp normalize_tmux_server(""), do: Tmux.managed_server()
  defp normalize_tmux_server(server), do: server

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {int, _rest} -> int
      :error -> 0
    end
  end

  defp clean(nil), do: nil
  defp clean(value) when is_binary(value), do: String.trim(value)
  defp clean(value), do: value
end
