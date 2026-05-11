defmodule JX.DevIDE.State do
  @moduledoc """
  Durable JX-side state derived from DevIDE's read-only HTTP API.

  This module is the extraction boundary for DevIDE ingestion. It persists the
  latest DevIDE workspace snapshot, emits JX monitor events for meaningful
  transitions, and creates JX notifications for new attention states.
  """

  import Ecto.Query

  alias JX.DevIDE.{Client, Portfolio, Status, WorkspaceSnapshot}
  alias JX.Approvals
  alias JX.MonitorEvents
  alias JX.Notifications
  alias JX.OperationalEvents
  alias JX.Repo

  @attention_statuses ~w(blocked needs_review)

  @spec ingest(Client.t(), keyword()) :: {:ok, map()} | {:error, Client.Error.t()}
  def ingest(%Client{} = client, opts \\ []) do
    with {:ok, portfolio} <- Portfolio.fetch_snapshot(client) do
      opts =
        opts
        |> Keyword.put_new(:source_url, client.base_url)
        |> Keyword.put_new(:now, DateTime.utc_now())

      {:ok, ingest_portfolio(portfolio, opts)}
    end
  end

  @spec ingest_portfolio(Portfolio.t(), keyword()) :: map()
  def ingest_portfolio(%Portfolio{} = portfolio, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    source_url = opts |> Keyword.get(:source_url, "") |> to_string()

    changes =
      portfolio
      |> statuses()
      |> Enum.map(&upsert_status(&1, now, source_url))
      |> Enum.filter(& &1.changed?)

    Enum.each(changes, &record_operational_change/1)

    {:ok, events} =
      changes
      |> Enum.flat_map(&monitor_events/1)
      |> Enum.reduce({:ok, []}, &record_event/2)

    notifications = Notifications.record_events(events)
    approvals = Approvals.record_devide_notifications(notifications.notifications)

    %{
      observed_at: now,
      source_url: source_url,
      portfolio: portfolio,
      workspaces_total: portfolio.total,
      changes: changes,
      events: events,
      notifications: notifications,
      approvals: approvals
    }
  end

  @spec list_snapshots(keyword()) :: [WorkspaceSnapshot.t()]
  def list_snapshots(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    WorkspaceSnapshot
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> order_by([snapshot],
      asc:
        fragment(
          "case ? when 'blocked' then 0 when 'needs_review' then 1 when 'unknown' then 2 else 3 end",
          snapshot.status
        ),
      asc: snapshot.name,
      asc: snapshot.workspace_id
    )
    |> limit(^limit)
    |> Repo.all()
  end

  @spec summary(keyword()) :: map()
  def summary(opts \\ []) do
    snapshots = list_snapshots(opts)
    by_status = Enum.frequencies_by(snapshots, & &1.status)

    %{
      generated_at: DateTime.utc_now(),
      source: "devide",
      total: length(snapshots),
      healthy: Map.get(by_status, "healthy", 0),
      blocked: Map.get(by_status, "blocked", 0),
      needs_review: Map.get(by_status, "needs_review", 0),
      unknown: Map.get(by_status, "unknown", 0),
      by_status: by_status,
      last_observed_at: latest_time(snapshots, & &1.last_observed_at),
      last_changed_at: latest_time(snapshots, & &1.last_changed_at),
      workspaces: Enum.map(snapshots, &snapshot_summary/1)
    }
  end

  @spec portfolio_totals(map()) :: map()
  def portfolio_totals(summary) when is_map(summary) do
    %{
      devide_workspaces: Map.get(summary, :total, 0),
      devide_healthy: Map.get(summary, :healthy, 0),
      devide_blocked: Map.get(summary, :blocked, 0),
      devide_needs_review: Map.get(summary, :needs_review, 0),
      devide_unknown: Map.get(summary, :unknown, 0)
    }
  end

  defp upsert_status(%Status{} = status, now, source_url) do
    digest = digest(status)
    fingerprint = fingerprint(digest)
    workspace_id = status.workspace.id
    previous = Repo.get_by(WorkspaceSnapshot, workspace_id: workspace_id)
    changed? = is_nil(previous) or previous.fingerprint != fingerprint
    last_changed_at = if changed?, do: now, else: previous.last_changed_at

    attrs =
      digest
      |> Map.merge(%{
        workspace_id: workspace_id,
        attention_flags: Jason.encode!(digest.attention_flags),
        snapshot: Jason.encode!(digest),
        fingerprint: fingerprint,
        source_url: source_url,
        last_observed_at: now,
        last_changed_at: last_changed_at
      })
      |> Map.drop([:id, :active_run, :latest_runs, :proposal_risks, :recent_blocks])

    snapshot = previous || %WorkspaceSnapshot{workspace_id: workspace_id}

    {:ok, updated} =
      snapshot
      |> WorkspaceSnapshot.changeset(attrs)
      |> Repo.insert_or_update()

    %{
      id: workspace_id,
      name: status.workspace.name,
      previous_status: previous && previous.status,
      status: Atom.to_string(status.status),
      changed?: changed?,
      attention_flags: status.attention_flags,
      previous: previous && snapshot_summary(previous),
      current: snapshot_summary(updated),
      snapshot: updated,
      digest: digest
    }
  end

  defp monitor_events(%{changed?: false}), do: []

  defp monitor_events(%{status: status} = change) when status in @attention_statuses do
    [
      %{
        kind: "devide.workspace.#{status}",
        severity: "warning",
        ref: change.id,
        project: change.name || "",
        session_type: "devide",
        session_kind: "workspace",
        control_mode: "read-only",
        work_state: status,
        action: "observe-devide",
        summary: event_summary(change),
        fingerprint: fingerprint(change.digest),
        payload: event_payload(change)
      }
    ]
  end

  defp monitor_events(%{previous_status: previous, status: "healthy"} = change)
       when previous in @attention_statuses do
    [
      %{
        kind: "devide.workspace.recovered",
        severity: "notice",
        ref: change.id,
        project: change.name || "",
        session_type: "devide",
        session_kind: "workspace",
        control_mode: "read-only",
        work_state: "healthy",
        action: "observe-devide",
        summary: event_summary(change),
        fingerprint: fingerprint(change.digest),
        payload: event_payload(change)
      }
    ]
  end

  defp monitor_events(_change), do: []

  defp record_operational_change(%{snapshot: %WorkspaceSnapshot{} = snapshot} = change) do
    _ = OperationalEvents.record_workspace_snapshot(snapshot, "devide.snapshot.changed")

    if change.status in @attention_statuses do
      snapshot.attention_flags
      |> decode_json([])
      |> Enum.each(fn risk -> _ = OperationalEvents.record_portfolio_risk(snapshot, risk) end)
    end
  end

  defp record_event(attrs, {:ok, acc}) do
    case MonitorEvents.record_event(attrs) do
      {:ok, events} -> {:ok, acc ++ events}
      {:error, reason} -> raise "DevIDE monitor event failed: #{inspect(reason)}"
    end
  end

  defp statuses(%Portfolio{} = portfolio) do
    portfolio.healthy ++ portfolio.blocked ++ portfolio.needs_review ++ portfolio.unknown
  end

  defp digest(%Status{} = status) do
    %{
      id: status.workspace.id,
      name: status.workspace.name || "",
      lifecycle_status: status.workspace.status || "",
      status: Atom.to_string(status.status),
      mode: status.mode || "",
      db_isolation: status.db_isolation || "unknown",
      active_run: status.active_run,
      latest_runs: status.latest_runs,
      proposal_risks: status.proposal_risks,
      recent_blocks: status.recent_blocks,
      attention_flags: Enum.sort(status.attention_flags)
    }
  end

  defp snapshot_summary(%WorkspaceSnapshot{} = snapshot) do
    decoded_snapshot = decode_json(snapshot.snapshot, %{})

    %{
      id: snapshot.workspace_id,
      name: snapshot.name,
      status: snapshot.status,
      lifecycle_status: snapshot.lifecycle_status,
      mode: snapshot.mode,
      db_isolation: snapshot.db_isolation,
      attention_flags: decode_json(snapshot.attention_flags, []),
      snapshot: decoded_snapshot,
      source_url: snapshot.source_url,
      last_observed_at: snapshot.last_observed_at,
      last_changed_at: snapshot.last_changed_at
    }
  end

  defp event_summary(change) do
    transition =
      case change.previous_status do
        nil -> change.status
        previous -> "#{previous}->#{change.status}"
      end

    flags =
      case change.attention_flags do
        [] -> "none"
        flags -> Enum.join(flags, ",")
      end

    "DevIDE workspace #{transition} | #{change.id} | #{change.name || "-"} | flags=#{flags}"
  end

  defp event_payload(change) do
    %{
      id: change.id,
      name: change.name,
      previous_status: change.previous_status,
      status: change.status,
      attention_flags: change.attention_flags,
      previous: change.previous,
      current: change.current
    }
  end

  defp latest_time([], _fun), do: nil

  defp latest_time(snapshots, fun) do
    snapshots
    |> Enum.map(fun)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort(&(DateTime.compare(&1, &2) != :gt))
    |> List.last()
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status),
    do: where(query, [snapshot], snapshot.status == ^status)

  defp fingerprint(payload) do
    payload
    |> :erlang.term_to_binary()
    |> then(fn binary -> :crypto.hash(:sha256, binary) end)
    |> Base.encode16(case: :lower)
  end

  defp decode_json(text, fallback) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> fallback
    end
  end

  defp decode_json(_text, fallback), do: fallback
end
