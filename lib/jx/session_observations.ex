defmodule JX.SessionObservations do
  @moduledoc """
  Persistence operations for read-only session observations.
  """

  import Ecto.Query

  alias JX.Repo
  alias JX.SessionObservations.SessionObservation

  @change_fields [
    :host,
    :transport,
    :type,
    :state,
    :kind,
    :agent_name,
    :task_id,
    :tmux_server,
    :session_name,
    :window,
    :pane,
    :pid,
    :ssh_target,
    :work_state,
    :capture_status,
    :summary
  ]

  @attention_work_states ~w(blocked waiting)
  @unknown_attention_types ~w(agent ssh task)

  def record_snapshot(%{sessions: sessions}), do: record_sessions(sessions)

  def record_sessions(sessions) do
    Repo.transaction(fn ->
      Enum.map(sessions, fn session ->
        attrs = observation_attrs(session)

        %SessionObservation{}
        |> SessionObservation.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, observation} -> observation
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  def list_observations(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    SessionObservation
    |> maybe_filter_ref(Keyword.get(opts, :ref))
    |> maybe_filter_work_state(Keyword.get(opts, :work_state))
    |> order_by([observation], desc: observation.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_changes(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    history_limit = Keyword.get(opts, :history_limit, max(limit * 5, 100))

    SessionObservation
    |> maybe_filter_ref(Keyword.get(opts, :ref))
    |> maybe_filter_refs(Keyword.get(opts, :refs))
    |> order_by([observation], desc: observation.id)
    |> limit(^history_limit)
    |> Repo.all()
    |> Enum.group_by(& &1.ref)
    |> Enum.map(&change_for_ref/1)
    |> Enum.reject(&is_nil/1)
    |> maybe_filter_change_work_state(Keyword.get(opts, :work_state))
    |> maybe_filter_attention(Keyword.get(opts, :attention, false))
    |> Enum.sort_by(& &1.observed_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  def list_stale(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    stale_after_seconds = Keyword.get(opts, :stale_after_seconds, 300)
    history_limit = Keyword.get(opts, :history_limit, max(limit * 5, 100))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    SessionObservation
    |> maybe_filter_ref(Keyword.get(opts, :ref))
    |> maybe_filter_host(Keyword.get(opts, :host))
    |> maybe_filter_type(Keyword.get(opts, :type))
    |> maybe_filter_work_state(Keyword.get(opts, :work_state))
    |> order_by([observation], desc: observation.id)
    |> limit(^history_limit)
    |> Repo.all()
    |> Enum.group_by(& &1.ref)
    |> Enum.map(fn {_ref, observations} ->
      observations
      |> Enum.max_by(& &1.id)
      |> stale_map(now)
    end)
    |> Enum.filter(&(&1.stale_seconds >= stale_after_seconds))
    |> Enum.sort_by(& &1.stale_seconds, :desc)
    |> Enum.take(limit)
  end

  def prune_missing_process_only(current_sessions, opts \\ []) do
    current_refs = Enum.map(current_sessions, & &1.ref)

    SessionObservation
    |> maybe_exclude_current_refs(current_refs)
    |> where([observation], observation.type in ["process", "ssh"])
    |> where(
      [observation],
      is_nil(observation.tmux_server) or observation.tmux_server == ""
    )
    |> where(
      [observation],
      is_nil(observation.session_name) or observation.session_name == ""
    )
    |> where([observation], is_nil(observation.window) and is_nil(observation.pane))
    |> maybe_filter_prune_host(Keyword.get(opts, :host))
    |> maybe_filter_prune_type(Keyword.get(opts, :type))
    |> maybe_filter_prune_ssh_target(Keyword.get(opts, :ssh_target))
    |> Repo.delete_all()
  end

  defp observation_attrs(session) do
    capture = Map.get(session, :capture, %{})

    %{
      ref: Map.get(session, :ref, ""),
      host: Map.get(session, :host, ""),
      transport: Map.get(session, :transport, ""),
      type: Map.get(session, :type, ""),
      state: Map.get(session, :state, ""),
      kind: Map.get(session, :kind, ""),
      agent_name: Map.get(session, :agent_name, ""),
      task_id: Map.get(session, :task_id, ""),
      tmux_server: Map.get(session, :server, ""),
      session_name: Map.get(session, :session, ""),
      window: Map.get(session, :window),
      pane: Map.get(session, :pane),
      pid: Map.get(session, :pid),
      ssh_target: Map.get(session, :ssh_target, ""),
      work_state: Map.get(capture, :work_state, "unknown"),
      capture_status: Map.get(capture, :status, "skipped"),
      summary: Map.get(capture, :summary, ""),
      snapshot: Jason.encode!(session)
    }
  end

  defp maybe_filter_ref(query, nil), do: query
  defp maybe_filter_ref(query, ref), do: where(query, [observation], observation.ref == ^ref)

  defp maybe_filter_refs(query, nil), do: query
  defp maybe_filter_refs(query, []), do: where(query, [_observation], false)
  defp maybe_filter_refs(query, refs), do: where(query, [observation], observation.ref in ^refs)

  defp maybe_filter_host(query, nil), do: query
  defp maybe_filter_host(query, host), do: where(query, [observation], observation.host == ^host)

  defp maybe_filter_type(query, nil), do: query
  defp maybe_filter_type(query, type), do: where(query, [observation], observation.type == ^type)

  defp maybe_filter_work_state(query, nil), do: query

  defp maybe_filter_work_state(query, work_state),
    do: where(query, [observation], observation.work_state == ^work_state)

  defp maybe_exclude_current_refs(query, []), do: query

  defp maybe_exclude_current_refs(query, refs) do
    where(query, [observation], observation.ref not in ^refs)
  end

  defp maybe_filter_prune_host(query, nil), do: query
  defp maybe_filter_prune_host(query, host), do: maybe_filter_host(query, host)

  defp maybe_filter_prune_type(query, nil), do: query

  defp maybe_filter_prune_type(query, type) when type in ["process", "ssh"],
    do: maybe_filter_type(query, type)

  defp maybe_filter_prune_type(query, _type), do: where(query, [_observation], false)

  defp maybe_filter_prune_ssh_target(query, nil), do: query

  defp maybe_filter_prune_ssh_target(query, target) do
    where(query, [observation], observation.ssh_target == ^target)
  end

  defp change_for_ref({_ref, observations}) do
    case Enum.sort_by(observations, & &1.id, :desc) do
      [] -> nil
      [latest] -> change_map(latest, nil, [])
      [latest, previous | _rest] -> change_map(latest, previous, changed_fields(latest, previous))
    end
  end

  defp change_map(latest, previous, changed_fields) do
    %{
      ref: latest.ref,
      host: latest.host,
      transport: latest.transport,
      type: latest.type,
      state: latest.state,
      kind: latest.kind || "",
      agent_name: latest.agent_name || "",
      task_id: latest.task_id || "",
      tmux_server: latest.tmux_server || "",
      session_name: latest.session_name || "",
      window: latest.window,
      pane: latest.pane,
      pid: latest.pid,
      ssh_target: latest.ssh_target || "",
      work_state: latest.work_state,
      previous_work_state: previous && previous.work_state,
      capture_status: latest.capture_status,
      previous_capture_status: previous && previous.capture_status,
      summary: latest.summary || "",
      previous_summary: previous && previous.summary,
      observed_at: latest.inserted_at,
      previous_observed_at: previous && previous.inserted_at,
      elapsed_seconds: elapsed_seconds(latest, previous),
      change: change_status(previous, changed_fields),
      changed_fields: Enum.map(changed_fields, &Atom.to_string/1),
      needs_attention: needs_attention?(latest, changed_fields)
    }
  end

  defp changed_fields(latest, previous) do
    Enum.filter(@change_fields, fn field ->
      Map.get(latest, field) != Map.get(previous, field)
    end)
  end

  defp change_status(nil, _changed_fields), do: "new"
  defp change_status(_previous, []), do: "same"
  defp change_status(_previous, _changed_fields), do: "changed"

  defp needs_attention?(observation, _changed_fields) do
    observation.work_state in @attention_work_states or
      (observation.work_state == "unknown" and observation.type in @unknown_attention_types) or
      observation.capture_status == "error"
  end

  defp elapsed_seconds(_latest, nil), do: nil

  defp elapsed_seconds(latest, previous) do
    DateTime.diff(latest.inserted_at, previous.inserted_at, :second)
  end

  defp maybe_filter_change_work_state(changes, nil), do: changes

  defp maybe_filter_change_work_state(changes, work_state) do
    Enum.filter(changes, &(&1.work_state == work_state))
  end

  defp maybe_filter_attention(changes, false), do: changes
  defp maybe_filter_attention(changes, true), do: Enum.filter(changes, & &1.needs_attention)

  defp stale_map(observation, now) do
    %{
      ref: observation.ref,
      host: observation.host,
      transport: observation.transport,
      type: observation.type,
      state: observation.state,
      kind: observation.kind || "",
      agent_name: observation.agent_name || "",
      task_id: observation.task_id || "",
      tmux_server: observation.tmux_server || "",
      session_name: observation.session_name || "",
      window: observation.window,
      pane: observation.pane,
      pid: observation.pid,
      ssh_target: observation.ssh_target || "",
      work_state: observation.work_state,
      capture_status: observation.capture_status,
      summary: observation.summary || "",
      observed_at: observation.inserted_at,
      stale_seconds: DateTime.diff(now, observation.inserted_at, :second),
      needs_attention:
        observation.work_state in @attention_work_states or observation.capture_status == "error"
    }
  end
end
