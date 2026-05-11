defmodule JX.OrchestratorHeartbeats do
  @moduledoc """
  Persistence for foreground-visible orchestrator daemon state.
  """

  import Ecto.Query

  alias JX.OrchestratorHeartbeats.Heartbeat
  alias JX.Repo

  def statuses, do: Heartbeat.statuses()

  def upsert(attrs) do
    attrs = Map.new(attrs)
    daemon_key = Map.get(attrs, :daemon_key) || Map.get(attrs, "daemon_key") || "orchestrator"

    heartbeat =
      Repo.get_by(Heartbeat, daemon_key: daemon_key) || %Heartbeat{daemon_key: daemon_key}

    heartbeat
    |> Heartbeat.changeset(Map.put(attrs, :daemon_key, daemon_key))
    |> Repo.insert_or_update()
  end

  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Heartbeat
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_consumer(Keyword.get(opts, :consumer))
    |> order_by([heartbeat], desc: heartbeat.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def get(daemon_key), do: Repo.get_by(Heartbeat, daemon_key: daemon_key)

  def health_alerts(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    stale_after_seconds = Keyword.get(opts, :stale_after_seconds, 120)

    opts
    |> Keyword.put_new(:limit, 50)
    |> list()
    |> Enum.flat_map(&heartbeat_health_alerts(&1, now, stale_after_seconds))
  end

  def mark_stopped(daemon_key, attrs \\ []) do
    attrs
    |> Map.new()
    |> Map.merge(%{
      daemon_key: daemon_key,
      status: "stopped",
      next_wake_at: nil,
      scan_snapshot: "{}"
    })
    |> upsert()
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status),
    do: where(query, [heartbeat], heartbeat.status == ^status)

  defp maybe_filter_consumer(query, nil), do: query

  defp maybe_filter_consumer(query, consumer),
    do: where(query, [heartbeat], heartbeat.consumer == ^consumer)

  defp heartbeat_health_alerts(heartbeat, now, stale_after_seconds) do
    []
    |> maybe_alert(error_alert(heartbeat))
    |> maybe_alert(stale_alert(heartbeat, now, stale_after_seconds))
    |> Enum.reverse()
  end

  defp error_alert(%Heartbeat{status: "stopped"}), do: nil

  defp error_alert(%Heartbeat{status: "error"} = heartbeat) do
    alert(
      heartbeat,
      "error",
      "critical",
      "orchestrator daemon #{heartbeat.daemon_key} reported an error"
    )
  end

  defp error_alert(%Heartbeat{last_error: error} = heartbeat)
       when is_binary(error) and error != "" do
    alert(
      heartbeat,
      "error",
      "warning",
      "orchestrator daemon #{heartbeat.daemon_key} has a recorded error"
    )
  end

  defp error_alert(_heartbeat), do: nil

  defp stale_alert(%Heartbeat{status: status}, _now, _stale_after_seconds)
       when status in ["stopped", "error"] do
    nil
  end

  defp stale_alert(%Heartbeat{next_wake_at: nil}, _now, _stale_after_seconds), do: nil

  defp stale_alert(%Heartbeat{} = heartbeat, now, stale_after_seconds) do
    overdue_seconds = DateTime.diff(now, heartbeat.next_wake_at, :second)

    if overdue_seconds > stale_after_seconds do
      heartbeat
      |> alert(
        "stale",
        "warning",
        "orchestrator daemon #{heartbeat.daemon_key} missed its wake by #{overdue_seconds}s"
      )
      |> Map.put(:overdue_seconds, overdue_seconds)
    end
  end

  defp maybe_alert(alerts, nil), do: alerts
  defp maybe_alert(alerts, alert), do: [alert | alerts]

  defp alert(heartbeat, reason, severity, summary) do
    %{
      kind: "orchestrator.health",
      reason: reason,
      severity: severity,
      daemon_key: heartbeat.daemon_key,
      consumer: heartbeat.consumer || "",
      session_name: heartbeat.session_name || "",
      status: heartbeat.status || "",
      mode: heartbeat.mode || "",
      last_scan_at: heartbeat.last_scan_at,
      last_decision_at: heartbeat.last_decision_at,
      last_error: heartbeat.last_error || "",
      next_wake_at: heartbeat.next_wake_at,
      summary: summary,
      fingerprint:
        "#{heartbeat.daemon_key}:#{reason}:#{heartbeat.status}:#{format_time(heartbeat.next_wake_at)}:#{heartbeat.last_error}"
    }
  end

  defp format_time(nil), do: ""
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
