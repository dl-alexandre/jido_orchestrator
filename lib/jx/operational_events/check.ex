defmodule JX.OperationalEvents.Check do
  @moduledoc """
  Read-only diagnostics for the operational event plane.

  The check command is intentionally non-repairing. It reports corrupted,
  unknown, or stale operational state so operators can decide whether to
  refresh DevIDE snapshots, release/reassign leases, or inspect action history.
  """

  import Ecto.Query

  alias JX.OperationalEvents
  alias JX.OperationalEvents.Event
  alias JX.OperationalEvents.Reducer
  alias JX.OperationalLeases.Lease
  alias JX.Repo

  @supported_event_version 1

  def run(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 10_000)
    events = OperationalEvents.list(limit: limit)
    state = Reducer.rebuild(events)

    issues =
      events
      |> Enum.flat_map(&event_issues/1)
      |> Kernel.++(lease_issues(now))
      |> Enum.sort_by(&{severity_rank(&1.severity), &1.id}, :desc)

    %{
      status: if(issues == [], do: "ok", else: "warning"),
      checked_at: now,
      events: length(events),
      issues: issues,
      rebuilt: %{
        workspaces: map_size(state.workspaces),
        approvals: map_size(state.approvals),
        actions: map_size(state.actions),
        leases: map_size(state.leases),
        agents: map_size(state.agents),
        runners: map_size(state.runners),
        assignments: map_size(state.assignments),
        runner_sessions: map_size(state.runner_sessions),
        timelines: map_size(state.timelines)
      },
      queue: Reducer.queue_state(state),
      next: next_steps(issues)
    }
  end

  defp event_issues(%Event{} = event) do
    payload_result = decode_payload(event.payload)

    []
    |> maybe_add(corrupt_payload_issue(event), match?({:error, _reason}, payload_result))
    |> maybe_add(unknown_entity_issue(event), event.entity_type not in Event.entity_types())
    |> maybe_add(missing_correlation_issue(event), event.correlation_id in [nil, ""])
    |> Kernel.++(future_version_issues(event, payload_result))
  end

  defp future_version_issues(_event, {:error, _reason}), do: []

  defp future_version_issues(event, {:ok, payload}) when is_map(payload) do
    case event_version(payload) do
      version when is_integer(version) and version > @supported_event_version ->
        [
          issue(
            event,
            "future_event_version",
            "warning",
            "event version #{version} is newer than supported version #{@supported_event_version}",
            "Upgrade jx before relying on this event for automated decisions."
          )
        ]

      _version ->
        []
    end
  end

  defp future_version_issues(_event, _payload), do: []

  defp lease_issues(now) do
    active_leases =
      Lease
      |> where([lease], lease.status == "active")
      |> Repo.all()

    active_leases
    |> Enum.flat_map(&single_lease_issues(&1, now))
    |> Kernel.++(duplicate_active_lease_issues(active_leases))
  end

  defp single_lease_issues(%Lease{} = lease, now) do
    []
    |> maybe_add(
      lease_issue(
        lease,
        "stale_active_lease",
        "warning",
        "active lease expired at #{format_time(lease.expires_at)}",
        "Run `jx leases reassign #{lease.resource_type} #{lease.resource_id} --owner <owner>` or release it if you own it."
      ),
      stale_active_lease?(lease, now)
    )
    |> maybe_add(
      lease_issue(
        lease,
        "lease_active_key_mismatch",
        "warning",
        "active lease key does not match #{lease.resource_type}:#{lease.resource_id}",
        "Inspect `jx leases ls --resource #{lease.resource_type}:#{lease.resource_id} --status all`."
      ),
      lease.active_key != "#{lease.resource_type}:#{lease.resource_id}"
    )
  end

  defp duplicate_active_lease_issues(active_leases) do
    active_leases
    |> Enum.group_by(&{&1.resource_type, &1.resource_id})
    |> Enum.flat_map(fn
      {_resource, [_lease]} ->
        []

      {{resource_type, resource_id}, leases} ->
        Enum.map(leases, fn lease ->
          lease_issue(
            lease,
            "duplicate_active_lease",
            "critical",
            "multiple active leases exist for #{resource_type}:#{resource_id}",
            "Stop execution for this resource and reassign it to one owner."
          )
        end)
    end)
  end

  defp corrupt_payload_issue(%Event{} = event) do
    issue(
      event,
      "corrupt_payload",
      "warning",
      "event payload is not valid JSON",
      "Keep the raw event for audit, then rebuild state from surrounding valid events."
    )
  end

  defp unknown_entity_issue(%Event{} = event) do
    issue(
      event,
      "unknown_entity_type",
      "warning",
      "unknown entity type #{inspect(event.entity_type)}",
      "Upgrade jx before using this event for automation; timeline display remains read-only."
    )
  end

  defp missing_correlation_issue(%Event{} = event) do
    issue(
      event,
      "missing_correlation_id",
      "warning",
      "event is missing a correlation_id",
      "Inspect adjacent timeline events before retrying or reproposing."
    )
  end

  defp issue(%Event{} = event, problem, severity, summary, next) do
    %{
      id: event.event_id,
      event_id: event.event_id,
      kind: event.kind,
      entity_type: event.entity_type,
      entity_id: event.entity_id,
      workspace_id: event.workspace_id,
      approval_id: event.approval_id,
      action_id: event.action_id,
      lease_id: event.lease_id,
      severity: severity,
      problem: problem,
      summary: summary,
      next: next
    }
  end

  defp lease_issue(%Lease{} = lease, problem, severity, summary, next) do
    %{
      id: lease.lease_id,
      event_id: "",
      kind: "lease.current_state",
      entity_type: "lease",
      entity_id: lease.lease_id,
      workspace_id: "",
      approval_id: if(lease.resource_type == "approval", do: lease.resource_id, else: ""),
      action_id: if(lease.resource_type == "action", do: lease.resource_id, else: ""),
      lease_id: lease.lease_id,
      severity: severity,
      problem: problem,
      summary: summary,
      next: next
    }
  end

  defp maybe_add(issues, issue, true), do: [issue | issues]
  defp maybe_add(issues, _issue, false), do: issues

  defp decode_payload(payload) when is_binary(payload), do: Jason.decode(payload)
  defp decode_payload(_payload), do: {:error, :non_string_payload}

  defp event_version(payload) do
    payload
    |> Map.get("event_version", Map.get(payload, "version"))
    |> parse_version()
  end

  defp parse_version(version) when is_integer(version), do: version

  defp parse_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {value, ""} -> value
      _other -> nil
    end
  end

  defp parse_version(_version), do: nil

  defp stale_active_lease?(%Lease{expires_at: nil}, _now), do: false

  defp stale_active_lease?(%Lease{expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt

  defp next_steps([]), do: ["No operational event issues detected."]

  defp next_steps(issues) do
    issues
    |> Enum.map(& &1.next)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp severity_rank("critical"), do: 4
  defp severity_rank("warning"), do: 3
  defp severity_rank("notice"), do: 2
  defp severity_rank("info"), do: 1
  defp severity_rank(_severity), do: 0

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value), do: to_string(value)
end
