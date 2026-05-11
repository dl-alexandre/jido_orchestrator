defmodule JX.OperationalEvents.Reducer do
  @moduledoc """
  Deterministic reducers for the append-only operational event stream.
  """

  alias JX.OperationalEvents
  alias JX.OperationalEvents.Event

  @spec rebuild([Event.t()]) :: map()
  def rebuild(events) when is_list(events) do
    events
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce(initial_state(), &apply_event/2)
  end

  def current_state(opts \\ []) do
    opts
    |> OperationalEvents.list()
    |> rebuild()
  end

  def queue_state(state) when is_map(state) do
    %{
      workspaces: state.workspaces,
      approvals: state.approvals,
      actions: state.actions,
      leases: state.leases,
      agents: state.agents,
      runners: state.runners,
      assignments: state.assignments,
      runner_sessions: state.runner_sessions,
      runtime_environments: state.runtime_environments,
      failures: failure_summary(state),
      open_approvals: count_by_status(state.approvals, "open"),
      planned_actions: count_by_status(state.actions, "planned"),
      active_leases: count_by_status(state.leases, "active"),
      active_assignments: count_active_assignments(state.assignments),
      busy_agents: count_by_status(state.agents, "busy"),
      busy_runners: count_by_status(state.runners, "busy"),
      active_runner_sessions: count_active_runner_sessions(state.runner_sessions),
      ready_runtime_environments: count_by_status(state.runtime_environments, "ready"),
      assigned_runtime_environments: count_by_status(state.runtime_environments, "assigned")
    }
  end

  def assignment_projection(state) when is_map(state), do: state.assignments

  def runner_fleet_state(state) when is_map(state) do
    %{
      runners: state.runners,
      sessions: state.runner_sessions,
      busy: count_by_status(state.runners, "busy"),
      stale: count_by_status(state.runners, "stale"),
      active_sessions: count_active_runner_sessions(state.runner_sessions)
    }
  end

  def queue_projection(state) when is_map(state), do: queue_state(state)

  def workspace_state(state) when is_map(state), do: state.workspaces

  def failure_summary(state) when is_map(state) do
    [
      state.assignments,
      state.runner_sessions,
      state.runtime_environments,
      state.runners,
      state.actions,
      state.workspaces
    ]
    |> Enum.flat_map(&Map.values/1)
    |> Enum.filter(&failure_projection?/1)
    |> Enum.group_by(&failure_class/1)
    |> Map.new(fn {class, values} ->
      {class,
       %{
         count: length(values),
         latest: List.last(values)
       }}
    end)
  end

  defp initial_state do
    %{
      workspaces: %{},
      approvals: %{},
      actions: %{},
      leases: %{},
      agents: %{},
      runners: %{},
      assignments: %{},
      runner_sessions: %{},
      runtime_environments: %{},
      timelines: %{}
    }
  end

  defp apply_event(%Event{} = event, state) do
    payload = OperationalEvents.decode_payload(event)

    state
    |> put_entity(event, payload)
    |> append_timeline(event, payload)
  end

  defp put_entity(
         %{workspaces: workspaces} = state,
         %Event{entity_type: "workspace"} = event,
         payload
       ) do
    Map.put(
      state,
      :workspaces,
      Map.put(workspaces, event.entity_id, entity_state(event, payload))
    )
  end

  defp put_entity(
         %{approvals: approvals} = state,
         %Event{entity_type: "approval"} = event,
         payload
       ) do
    Map.put(state, :approvals, Map.put(approvals, event.entity_id, entity_state(event, payload)))
  end

  defp put_entity(%{actions: actions} = state, %Event{entity_type: "action"} = event, payload) do
    Map.put(state, :actions, Map.put(actions, event.entity_id, entity_state(event, payload)))
  end

  defp put_entity(%{leases: leases} = state, %Event{entity_type: "lease"} = event, payload) do
    Map.put(state, :leases, Map.put(leases, event.entity_id, entity_state(event, payload)))
  end

  defp put_entity(%{agents: agents} = state, %Event{entity_type: "agent"} = event, payload) do
    Map.put(state, :agents, Map.put(agents, event.entity_id, entity_state(event, payload)))
  end

  defp put_entity(%{runners: runners} = state, %Event{entity_type: "runner"} = event, payload) do
    Map.put(state, :runners, Map.put(runners, event.entity_id, entity_state(event, payload)))
  end

  defp put_entity(
         %{assignments: assignments} = state,
         %Event{entity_type: "assignment"} = event,
         payload
       ) do
    Map.put(
      state,
      :assignments,
      Map.put(assignments, event.entity_id, entity_state(event, payload))
    )
  end

  defp put_entity(
         %{runner_sessions: runner_sessions} = state,
         %Event{entity_type: "runner_session"} = event,
         payload
       ) do
    Map.put(
      state,
      :runner_sessions,
      Map.put(runner_sessions, event.entity_id, entity_state(event, payload))
    )
  end

  defp put_entity(
         %{runtime_environments: runtime_environments} = state,
         %Event{entity_type: "runtime_environment"} = event,
         payload
       ) do
    Map.put(
      state,
      :runtime_environments,
      Map.put(runtime_environments, event.entity_id, entity_state(event, payload))
    )
  end

  defp put_entity(state, _event, _payload), do: state

  defp entity_state(%Event{} = event, payload) do
    %{
      id: event.entity_id,
      kind: event.kind,
      source: event.source,
      correlation_id: event.correlation_id,
      workspace_id: event.workspace_id,
      approval_id: event.approval_id,
      action_id: event.action_id,
      lease_id: event.lease_id,
      owner: event.owner,
      severity: event.severity,
      summary: event.summary,
      status: payload["status"] || payload[:status] || "",
      failure_class: payload["failure_class"] || payload[:failure_class] || "",
      payload: payload,
      updated_at: event.inserted_at
    }
  end

  defp append_timeline(%{timelines: timelines} = state, %Event{} = event, payload) do
    keys =
      [
        timeline_key(:workspace, event.workspace_id),
        timeline_key(:approval, event.approval_id),
        timeline_key(:action, event.action_id),
        timeline_key(:lease, event.lease_id),
        if(event.entity_type == "assignment", do: timeline_key(:assignment, event.entity_id)),
        if(event.entity_type == "assignment", do: timeline_key(:agent, event.owner)),
        if(event.entity_type == "agent", do: timeline_key(:agent, event.entity_id)),
        if(event.entity_type == "runner", do: timeline_key(:runner, event.entity_id)),
        if(event.entity_type == "runner_session", do: timeline_key(:session, event.entity_id)),
        if(event.entity_type == "runner_session", do: timeline_key(:runner, event.owner)),
        if(event.entity_type == "runtime_environment",
          do: timeline_key(:runtime, event.entity_id)
        ),
        if(event.entity_type == "runtime_environment", do: timeline_key(:runner, event.owner)),
        if(event.entity_type == "runner_session",
          do: timeline_key(:assignment, payload["assignment_id"] || payload[:assignment_id])
        )
      ]
      |> Enum.reject(&is_nil/1)

    entry = %{
      event_id: event.event_id,
      kind: event.kind,
      correlation_id: event.correlation_id,
      entity_type: event.entity_type,
      entity_id: event.entity_id,
      summary: event.summary,
      payload: payload,
      inserted_at: event.inserted_at
    }

    updated =
      Enum.reduce(keys, timelines, fn key, acc ->
        Map.update(acc, key, [entry], &(&1 ++ [entry]))
      end)

    Map.put(state, :timelines, updated)
  end

  defp timeline_key(_scope, ""), do: nil
  defp timeline_key(_scope, nil), do: nil
  defp timeline_key(scope, id), do: "#{scope}:#{id}"

  defp count_by_status(map, status) do
    map
    |> Map.values()
    |> Enum.count(&(&1.status == status))
  end

  defp count_active_assignments(map) do
    map
    |> Map.values()
    |> Enum.count(&(&1.status in ["created", "claimed", "started", "progressed"]))
  end

  defp count_active_runner_sessions(map) do
    map
    |> Map.values()
    |> Enum.count(&(&1.status in ["created", "claimed", "running", "progressed", "stale"]))
  end

  defp failure_projection?(entry) do
    entry.severity in ["warning", "error"] or entry.failure_class not in [nil, ""]
  end

  defp failure_class(%{failure_class: failure_class}) when failure_class not in [nil, ""],
    do: failure_class

  defp failure_class(%{kind: kind}) when is_binary(kind) do
    cond do
      String.contains?(kind, "enqueue_failed") -> "enqueue_failed"
      String.contains?(kind, "expired") -> "lease_expired"
      String.contains?(kind, "failed") -> "action_failed"
      String.contains?(kind, "mismatch") -> "replay_mismatch"
      true -> "report_rejected"
    end
  end
end
