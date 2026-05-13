defmodule JX.HostCapacity do
  @moduledoc """
  Probes hosts for available hardware resources and computes how many concurrent
  worktree + agent sessions each host can sustain.

  ## Agent profiles

  An agent profile describes the expected resource footprint of a single
  worktree session: the AI agent process, the language runtime under test, and
  any ancillary build/test tooling.  The default profile is calibrated for an
  Elixir/Phoenix project (like OneBackend-v3) running a full agentic session:

  | component            | estimate |
  |----------------------|----------|
  | AI agent process     | ~1.5 GB  |
  | BEAM VM + test suite | ~1.0 GB  |
  | OS / page-cache churn| ~0.5 GB  |
  | **total RAM/slot**   | **3 GB** |
  | git worktree + build | ~2 GB    |
  | average CPU load     | 0.4 core |

  These can be overridden per call via the `profile:` option.

  ## Capacity formula

      max_by_ram  = floor(available_ram_mb  / profile.ram_mb_per_slot)
      max_by_disk = floor(available_disk_mb / profile.disk_mb_per_slot)
      max_by_cpu  = floor(cpu_cores         / profile.cpu_cores_per_slot)
      recommended = min(max_by_ram, max_by_disk, max_by_cpu)

  The probe queries whatever is available on the host – macOS `sysctl`/`vm_stat`
  or Linux `/proc/meminfo` – via the existing SSH adapter.
  """

  alias JX.Hosts.Host
  alias JX.SSH

  # ---------------------------------------------------------------------------
  # Default profile: Elixir/Phoenix project + AI agent (claude/opencode/codex)
  # ---------------------------------------------------------------------------

  @default_profile %{
    name: "elixir-phoenix-agent",
    # RAM that each worktree+agent session is expected to consume (MB)
    ram_mb_per_slot: 3_072,
    # Disk that each worktree (source tree + _build) is expected to occupy (MB)
    disk_mb_per_slot: 2_048,
    # Fractional CPU cores consumed on average per session (bursty during compile)
    cpu_cores_per_slot: 0.4
  }

  def default_profile, do: @default_profile

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  SSH-probes `host` for RAM, disk, and CPU, then computes how many concurrent
  worktree sessions it can sustain under the given resource `profile`.

  Returns `{:ok, result}` or `{:error, reason}`.

  The result map contains:

      %{
        host:               host.name,
        resources:          %{ram_total_mb, ram_available_mb, disk_total_mb,
                               disk_available_mb, cpu_cores},
        profile:            %{name, ram_mb_per_slot, disk_mb_per_slot, cpu_cores_per_slot},
        limits:             %{by_ram, by_disk, by_cpu},
        recommended_worktrees: non_neg_integer
      }
  """
  @spec assess(%Host{}, keyword()) :: {:ok, map()} | {:error, term()}
  def assess(%Host{} = host, opts \\ []) do
    profile = Keyword.get(opts, :profile, @default_profile)

    with {:ok, resources} <- probe(host) do
      limits = %{
        by_ram: safe_floor(resources.ram_available_mb, profile.ram_mb_per_slot),
        by_disk: safe_floor(resources.disk_available_mb, profile.disk_mb_per_slot),
        by_cpu: safe_floor(resources.cpu_cores, profile.cpu_cores_per_slot)
      }

      formula_recommended = limits |> Map.values() |> Enum.min() |> max(0)

      # If the operator has explicitly set a capacity_limit, honour it as the
      # ceiling but still surface the formula result for comparison.
      {recommended, source} =
        case host.capacity_limit do
          nil -> {formula_recommended, :formula}
          limit -> {limit, :operator}
        end

      {:ok,
       %{
         host: host.name,
         resources: resources,
         profile: profile,
         limits: limits,
         formula_recommended: formula_recommended,
         recommended_worktrees: recommended,
         limit_source: source
       }}
    end
  end

  @doc """
  Probes `host` for raw hardware resources without computing capacity.

  Returns `{:ok, resources}` or `{:error, reason}`.

      %{
        ram_total_mb:      integer,
        ram_available_mb:  integer,
        disk_total_mb:     integer,
        disk_available_mb: integer,
        cpu_cores:         integer
      }
  """
  @spec probe(%Host{}) :: {:ok, map()} | {:error, term()}
  def probe(%Host{} = host) do
    with {:ok, ram} <- probe_ram(host),
         {:ok, disk} <- probe_disk(host, host.workspace_path),
         {:ok, cores} <- probe_cpu(host) do
      {:ok, Map.merge(ram, Map.merge(disk, %{cpu_cores: cores}))}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers – hardware probes (cross-platform shell scripts)
  # ---------------------------------------------------------------------------

  defp probe_ram(%Host{} = host) do
    script = """
    set -eu
    if command -v sysctl >/dev/null 2>&1 && sysctl -n hw.memsize >/dev/null 2>&1; then
      # macOS
      total_bytes=$(sysctl -n hw.memsize)
      total_mb=$(( total_bytes / 1048576 ))
      free_pages=$(vm_stat | awk '/^Pages free:/ { gsub(/\\./, "", $3); print $3 + 0 }')
      inactive_pages=$(vm_stat | awk '/^Pages inactive:/ { gsub(/\\./, "", $3); print $3 + 0 }')
      avail_mb=$(( (free_pages + inactive_pages) * 4096 / 1048576 ))
      printf "%d %d" "$total_mb" "$avail_mb"
    else
      # Linux
      awk '/MemTotal:/    { total=$2 }
           /MemAvailable:/ { avail=$2 }
           END { printf "%d %d", int(total/1024), int(avail/1024) }' /proc/meminfo
    fi
    """

    case SSH.adapter(host).run(host, script) do
      {:ok, output} -> parse_two_ints(output, :ram_total_mb, :ram_available_mb)
      {:error, _} = err -> err
    end
  end

  defp probe_disk(%Host{} = host, workspace_path) do
    # df -m prints 1-MiB-block output; column 2 = total, column 4 = available.
    # We check the filesystem that contains the workspace (or / if the path doesn't
    # exist yet) so the number reflects usable space where worktrees will land.
    script = """
    set -eu
    path=#{JX.Shell.quote(workspace_path || "/")}
    # Fall back to / if the workspace path doesn't exist yet.
    test -e "$path" || path="/"
    df -m "$path" | awk 'NR==2 { printf "%d %d", $2, $4 }'
    """

    case SSH.adapter(host).run(host, script) do
      {:ok, output} -> parse_two_ints(output, :disk_total_mb, :disk_available_mb)
      {:error, _} = err -> err
    end
  end

  defp probe_cpu(%Host{} = host) do
    script = """
    set -eu
    if command -v sysctl >/dev/null 2>&1 && sysctl -n hw.logicalcpu >/dev/null 2>&1; then
      sysctl -n hw.logicalcpu
    elif command -v nproc >/dev/null 2>&1; then
      nproc
    else
      grep -c '^processor' /proc/cpuinfo
    fi
    """

    case SSH.adapter(host).run(host, script) do
      {:ok, output} ->
        case Integer.parse(String.trim(output)) do
          {n, _} when n > 0 -> {:ok, n}
          _ -> {:error, {:parse_error, "unexpected cpu output: #{output}"}}
        end

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Utilities
  # ---------------------------------------------------------------------------

  defp parse_two_ints(output, key_a, key_b) do
    case String.split(String.trim(output)) do
      [a_s, b_s] ->
        with {a, _} <- Integer.parse(a_s),
             {b, _} <- Integer.parse(b_s) do
          {:ok, %{key_a => a, key_b => b}}
        else
          _ -> {:error, {:parse_error, "could not parse integers from: #{output}"}}
        end

      _ ->
        {:error, {:parse_error, "expected two integers, got: #{output}"}}
    end
  end

  defp safe_floor(_available, per_slot) when per_slot <= 0, do: 0
  defp safe_floor(available, per_slot), do: floor(available / per_slot)
end
