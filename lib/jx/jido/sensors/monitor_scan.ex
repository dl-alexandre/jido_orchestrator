defmodule JX.Jido.Sensors.MonitorScan do
  @moduledoc """
  Scheduled Jido sensor for `JX.Workspace.monitor_scan/1`.

  The sensor emits compact scan lifecycle signals. Individual monitor events are
  still persisted and dispatched by `JX.MonitorEvents` during the scan.
  """

  use Jido.Sensor,
    name: "jx_monitor_scan",
    description: "Runs Workspace monitor scans on a supervised Jido sensor schedule",
    schema:
      Zoi.object(
        %{
          interval_ms:
            Zoi.integer(description: "Interval between monitor scans in milliseconds")
            |> Zoi.min(1)
            |> Zoi.default(30_000),
          run_on_start:
            Zoi.boolean(description: "Run one scan immediately after startup")
            |> Zoi.default(false),
          opts:
            Zoi.any(description: "Workspace.monitor_scan/1 options")
            |> Zoi.default([])
        },
        coerce: true
      )

  alias JX.Workspace

  @completed_signal_type "jx.monitor.scan.completed"
  @failed_signal_type "jx.monitor.scan.failed"
  @source "/jx/sensors/monitor_scan"

  def completed_signal_type, do: @completed_signal_type
  def failed_signal_type, do: @failed_signal_type

  @impl true
  def init(config, _context) do
    state = %{
      interval_ms: config.interval_ms,
      opts: normalize_workspace_opts(config.opts),
      scans_total: 0,
      last_scan_at: nil,
      last_status: "idle"
    }

    first_interval = if config.run_on_start, do: 1, else: config.interval_ms

    {:ok, state, [{:schedule, first_interval, :scan}]}
  end

  @impl true
  def handle_event(:tick, state), do: handle_event(:scan, state)

  def handle_event(:scan, state) do
    scan_started_at = DateTime.utc_now()

    case Workspace.monitor_scan(state.opts) do
      {:ok, scan} ->
        state = next_state(state, "completed", scan_started_at)
        signal = completed_signal(scan, state)

        {:ok, state, [{:emit, signal}, {:schedule, state.interval_ms, :scan}]}

      {:error, reason} ->
        state = next_state(state, "failed", scan_started_at)
        signal = failed_signal(reason, state)

        {:ok, state, [{:emit, signal}, {:schedule, state.interval_ms, :scan}]}
    end
  end

  def handle_event(_event, state), do: {:ok, state}

  defp completed_signal(scan, state) do
    Jido.Signal.new!(@completed_signal_type, completed_data(scan, state),
      source: @source,
      subject: "monitor_scan"
    )
  end

  defp failed_signal(reason, state) do
    Jido.Signal.new!(@failed_signal_type, failed_data(reason, state),
      source: @source,
      subject: "monitor_scan"
    )
  end

  defp completed_data(scan, state) do
    %{
      status: "completed",
      generated_at: iso8601(Map.get(scan, :generated_at)),
      scan_total: state.scans_total,
      scan_started_at: iso8601(state.last_scan_at),
      observed: Map.get(scan, :observed, false),
      sessions_total: Map.get(scan, :sessions_total, 0),
      events_saved: Map.get(scan, :events_saved, 0),
      queues_total: Map.get(scan, :queues_total, 0),
      profiles_total: Map.get(scan, :profiles_total, 0),
      notifications_saved: Map.get(scan, :notifications_saved, 0),
      errors_total: length(Map.get(scan, :errors, [])),
      error: ""
    }
  end

  defp failed_data(reason, state) do
    %{
      status: "failed",
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      scan_total: state.scans_total,
      scan_started_at: iso8601(state.last_scan_at),
      observed: false,
      sessions_total: 0,
      events_saved: 0,
      queues_total: 0,
      profiles_total: 0,
      notifications_saved: 0,
      errors_total: 1,
      error: inspect(reason)
    }
  end

  defp next_state(state, status, scan_started_at) do
    %{
      state
      | scans_total: state.scans_total + 1,
        last_scan_at: scan_started_at,
        last_status: status
    }
  end

  defp normalize_workspace_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_workspace_opts(opts) when is_list(opts), do: opts
  defp normalize_workspace_opts(_opts), do: []

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: ""
end
