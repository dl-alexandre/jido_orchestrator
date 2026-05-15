defmodule JX.HostCapacity.CapacityPoller do
  @moduledoc """
  Periodic GenServer that takes background capacity snapshots for every host
  that currently has one or more active task sessions.

  Snapshots from this poller give the `Evaluator` data points collected *during*
  long-running sessions, not just at transition boundaries.  Without this,
  a host running a 2-hour agent session would only contribute two observations
  (launch and completion) instead of the ~24 mid-session readings that a 5-minute
  poll interval would produce.

  The poll interval is configurable:

      config :jx, JX.HostCapacity.CapacityPoller, poll_interval_ms: 300_000

  Defaults to 5 minutes.  Set to 0 to disable polling (useful in tests).
  """

  use GenServer

  require Logger

  alias JX.Fanout
  alias JX.HostCapacity.Observer
  alias JX.Hosts
  alias JX.Tasks

  @default_interval_ms 5 * 60 * 1_000
  @default_runs_root "~/.jx/runs"

  # Caps on parallel per-host snapshot work. SSH probes are the slow leg —
  # one bad host must not drag the whole cycle. Per-host timeout kills a
  # stuck probe so the next cycle can still run cleanly.
  @poll_max_concurrency 4
  @poll_per_host_timeout_ms 30_000

  # ---------------------------------------------------------------------------
  # Supervision API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    interval = poll_interval_ms()

    if interval > 0 do
      schedule_poll(interval)
    end

    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:poll, %{interval: interval} = state) do
    poll_all_active_hosts()

    if interval > 0 do
      schedule_poll(interval)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp poll_all_active_hosts do
    runs_root = Path.expand(runs_root())

    # Per-host fanout active counts across all run directories.
    fanout_by_host =
      if File.dir?(runs_root) do
        Fanout.active_assignments_per_host(runs_root)
      else
        %{}
      end

    hosts_with_active_sessions =
      Hosts.list_hosts()
      |> Enum.map(fn host ->
        task_active = Tasks.count_running_for_host(host.id)
        fanout_active = Map.get(fanout_by_host, host.name, 0)
        total = task_active + fanout_active
        {host, total}
      end)
      |> Enum.filter(fn {_host, total} -> total > 0 end)

    # Run snapshots concurrently under the supervised Task supervisor
    # (added in /phx:perf #5). Replaces the previous serial Enum.each so
    # one slow / laggy SSH host can't drag the entire poll cycle, and
    # gives each probe a per-host timeout that kills only that one task.
    hosts_with_active_sessions
    |> Task.Supervisor.async_stream(
      JX.TaskSupervisor,
      fn {host, active} -> {host, active, Observer.snapshot(host, active)} end,
      max_concurrency: @poll_max_concurrency,
      timeout: @poll_per_host_timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.each(fn
      {:ok, {host, active, {:ok, _obs}}} ->
        Logger.debug("[CapacityPoller] snapshot recorded for #{host.name} (#{active} active)")

      {:ok, {host, _active, {:error, reason}}} ->
        Logger.warning("[CapacityPoller] snapshot failed for #{host.name}: #{inspect(reason)}")

      {:exit, reason} ->
        Logger.warning("[CapacityPoller] snapshot task exited: #{inspect(reason)}")
    end)
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp poll_interval_ms do
    :jx
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:poll_interval_ms, @default_interval_ms)
  end

  defp runs_root do
    :jx
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:runs_root, @default_runs_root)
  end
end
