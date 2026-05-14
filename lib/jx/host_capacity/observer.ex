defmodule JX.HostCapacity.Observer do
  @moduledoc """
  Takes a hardware snapshot of a host while sessions are running and persists
  it as a `JX.HostCapacity.Observation`.

  Call `snapshot/2` after launching or completing a worktree session so that
  the evaluator has real-world data to work from.  The active session count is
  passed in by the caller rather than queried here so the observer stays
  decoupled from task/assignment state.

  ## Load average

  On hosts that expose a 1-minute load average (`uptime` or `/proc/loadavg`)
  the value is stored alongside the RAM/disk/CPU readings.  It gives the
  evaluator a signal about CPU pressure that the raw core count can't express.
  """

  import Ecto.Query

  alias JX.HostCapacity
  alias JX.HostCapacity.Observation
  alias JX.Hosts.Host
  alias JX.Repo
  alias JX.SSH

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Probes `host`, counts `active_sessions`, and inserts an `Observation`.

  Returns `{:ok, observation}` or `{:error, reason}`.
  """
  @spec snapshot(%Host{}, non_neg_integer()) :: {:ok, Observation.t()} | {:error, term()}
  def snapshot(%Host{} = host, active_sessions) when is_integer(active_sessions) do
    with {:ok, resources} <- HostCapacity.probe(host),
         {:ok, load_avg} <- probe_load_avg(host) do
      attrs = %{
        host_name: host.name,
        active_sessions: active_sessions,
        ram_total_mb: resources.ram_total_mb,
        ram_available_mb: resources.ram_available_mb,
        disk_total_mb: resources.disk_total_mb,
        disk_available_mb: resources.disk_available_mb,
        cpu_cores: resources.cpu_cores,
        load_avg_1m: load_avg,
        capacity_limit_at_observation: host.capacity_limit
      }

      %Observation{}
      |> Observation.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Returns the `n` most recent observations for `host_name`.
  """
  @spec recent(String.t(), pos_integer()) :: [Observation.t()]
  def recent(host_name, n \\ 50) do
    Observation
    |> where([o], o.host_name == ^host_name)
    |> order_by([o], desc: o.inserted_at)
    |> limit(^n)
    |> Repo.all()
  end

  @doc """
  Returns all observations for `host_name` where at least one session was
  active.  These are the meaningful data points for calibration.
  """
  @spec under_load(String.t()) :: [Observation.t()]
  def under_load(host_name) do
    Observation
    |> where([o], o.host_name == ^host_name and o.active_sessions > 0)
    |> order_by([o], asc: o.inserted_at)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Private – load average probe
  # ---------------------------------------------------------------------------

  defp probe_load_avg(%Host{} = host) do
    # Always probe the host directly via the SSH adapter, bypassing any
    # validation_prefix (e.g. "docker compose run --rm app").  This ensures
    # we read host-level load, not container-level load.
    #
    # Priority order:
    #   1. /proc/loadavg  – Linux bare-metal and most container hosts that
    #      expose host procfs (or have their own scheduler info)
    #   2. sysctl kern.boottime trick (macOS)  – load avg via sysctl vm.loadavg
    #   3. uptime(1)  – fallback; parsed carefully to handle both Linux and
    #      macOS output formats without relying on locale-specific words
    #   4. Empty string  – host doesn't expose any load avg; stored as nil
    script = """
    set -eu
    if [ -r /proc/loadavg ]; then
      awk '{ printf "%.2f", $1 }' /proc/loadavg
    elif command -v sysctl >/dev/null 2>&1 && sysctl -n vm.loadavg >/dev/null 2>&1; then
      sysctl -n vm.loadavg | awk '{ printf "%.2f", $2 }'
    elif command -v uptime >/dev/null 2>&1; then
      uptime | awk '
        /load average/  { match($0, /load average[s]?:[ \t]*([0-9.]+)/, a); if (a[1]) { printf "%.2f", a[1]; exit } }
        /load averages/ { match($0, /load averages:[ \t]*([0-9.]+)/, a); if (a[1]) { printf "%.2f", a[1]; exit } }
      '
    else
      printf ""
    fi
    """

    case SSH.adapter(host).run(host, script) do
      {:ok, output} ->
        trimmed = String.trim(output)

        if trimmed == "" do
          {:ok, nil}
        else
          case Float.parse(trimmed) do
            {v, _} -> {:ok, v}
            :error -> {:ok, nil}
          end
        end

      {:error, _} ->
        # Load avg is optional; don't fail the whole snapshot
        {:ok, nil}
    end
  end
end
