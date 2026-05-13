defmodule JX.CLI.Host do
  @moduledoc false

  alias JX.AgentRunner
  alias JX.HostDoctor
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @host_doctor_usage "jx host doctor <host> [--agent claude|opencode|codex] [--transport native|acpx]"
  @host_add_usage "jx host add <name> (--ssh <user@host> | --local) --workspace <path>"
  @hosts_doctor_usage "jx hosts doctor [--agent claude|opencode|codex] [--transport native|acpx] [--json]"
  @host_capacity_usage "jx host capacity <host> [--ram <mb>] [--disk <mb>] [--cpu <cores>]"
  @host_capacity_set_usage "jx host capacity set <host> <n>"
  @host_capacity_eval_usage "jx host capacity eval <host>"
  @hosts_capacity_usage "jx hosts capacity [--ram <mb>] [--disk <mb>] [--cpu <cores>] [--json]"
  @hosts_capacity_eval_usage "jx hosts capacity eval [--json]"

  def usage_lines(:host),
    do: [
      @host_add_usage,
      "jx host ls",
      @host_doctor_usage,
      @host_capacity_usage,
      @host_capacity_set_usage,
      @host_capacity_eval_usage
    ]

  def usage_lines(:hosts), do: [@hosts_doctor_usage, @hosts_capacity_usage, @hosts_capacity_eval_usage]

  def run(["add", name | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [ssh: :string, workspace: :string, local: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @host_add_usage),
         {:ok, attrs} <- host_attrs(name, parsed),
         :ok <- start_app(opts),
         {:ok, host} <- apply(workspace(opts), :add_host, [attrs]) do
      IO.puts(host_registered_text(host))
      :ok
    end
  end

  def run(["doctor", name | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [agent: :string, transport: :string])

    agent_name = parsed[:agent]
    agent_transport = parsed[:transport] || AgentRunner.default_agent_transport()

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @host_doctor_usage),
         :ok <- validate_optional_agent_name(agent_name),
         :ok <- validate_agent_transport(agent_transport),
         :ok <- start_app(opts),
         {:ok, report} <-
           apply(workspace(opts), :doctor_host, [name, doctor_opts(agent_name, agent_transport)]) do
      print_doctor_report(report)

      if HostDoctor.passed?(report) do
        :ok
      else
        {:error, "doctor checks failed"}
      end
    end
  end

  def run(["ls"], opts) do
    with :ok <- start_app(opts) do
      opts
      |> workspace()
      |> apply(:list_hosts, [])
      |> print_hosts()

      :ok
    end
  end

  def run(["capacity", "set", name, raw_limit | rest], opts) do
    with :ok <- expect_no_args(rest, @host_capacity_set_usage),
         {limit, ""} <- Integer.parse(raw_limit),
         true <- limit > 0 || {:error, "limit must be a positive integer"},
         :ok <- start_app(opts),
         {:ok, host} <- apply(workspace(opts), :set_capacity_limit, [name, limit]) do
      IO.puts("host #{host.name} capacity limit set to #{host.capacity_limit}")
      :ok
    else
      :error -> {:error, "limit must be a positive integer"}
      {_, _} -> {:error, "limit must be a positive integer"}
      other -> other
    end
  end

  def run(["capacity", "eval", name | rest], opts) do
    with :ok <- expect_no_args(rest, @host_capacity_eval_usage),
         :ok <- start_app(opts),
         {:ok, result} <- apply(workspace(opts), :evaluate_capacity, [name]) do
      print_eval_result(result)
      :ok
    end
  end

  def run(["capacity", name | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [ram: :integer, disk: :integer, cpu: :float])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @host_capacity_usage),
         :ok <- start_app(opts),
         {:ok, result} <-
           apply(workspace(opts), :capacity_host, [name, capacity_opts(parsed)]) do
      print_capacity_result(result)
      :ok
    end
  end

  def run(["doctor" | _args], _opts), do: {:error, "usage: #{@host_doctor_usage}"}
  def run(_args, _opts), do: {:error, "usage: #{@host_add_usage} | #{@host_doctor_usage}"}

  def run_plural(["capacity", "eval" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @hosts_capacity_eval_usage),
         :ok <- start_app(opts),
         {:ok, report} <- apply(workspace(opts), :evaluate_all_capacity, []) do
      print_hosts_eval_report(report, json: parsed[:json] || false)
      :ok
    end
  end

  def run_plural(["capacity" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [ram: :integer, disk: :integer, cpu: :float, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @hosts_capacity_usage),
         :ok <- start_app(opts),
         {:ok, report} <-
           apply(workspace(opts), :capacity_hosts, [capacity_opts(parsed)]) do
      print_hosts_capacity_report(report, json: parsed[:json] || false)
      :ok
    end
  end

  def run_plural(["doctor" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [agent: :string, transport: :string, json: :boolean])

    agent_name = parsed[:agent]
    agent_transport = parsed[:transport] || AgentRunner.default_agent_transport()

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @hosts_doctor_usage),
         :ok <- validate_optional_agent_name(agent_name),
         :ok <- validate_agent_transport(agent_transport),
         :ok <- start_app(opts),
         {:ok, report} <-
           apply(workspace(opts), :doctor_hosts, [doctor_opts(agent_name, agent_transport)]) do
      print_hosts_doctor_report(report, json: parsed[:json] || false)

      if Enum.all?(report.reports, &HostDoctor.passed?/1) do
        :ok
      else
        {:error, "doctor checks failed"}
      end
    end
  end

  def run_plural(_args, _opts), do: {:error, "usage: #{@hosts_doctor_usage}"}

  defp host_attrs(name, opts) do
    cond do
      opts[:local] && opts[:ssh] ->
        {:error, "use either --local or --ssh, not both"}

      opts[:local] ->
        {:ok, %{name: name, transport: "local", workspace_path: opts[:workspace]}}

      true ->
        {:ok,
         %{
           name: name,
           transport: "ssh",
           ssh_target: opts[:ssh],
           workspace_path: opts[:workspace]
         }}
    end
  end

  defp host_registered_text(%{transport: "local"} = host) do
    "host #{host.name} registered: local workspace=#{host.workspace_path}"
  end

  defp host_registered_text(host) do
    "host #{host.name} registered: #{host.ssh_target} workspace=#{host.workspace_path}"
  end

  defp doctor_opts(agent_name, agent_transport) do
    []
    |> put_present_kw(:agent_transport, agent_transport)
    |> put_present_kw(:agents, doctor_agents(agent_name))
  end

  defp doctor_agents(nil), do: nil
  defp doctor_agents(agent_name), do: [agent_name]

  defp put_present_kw(attrs, _key, nil), do: attrs
  defp put_present_kw(attrs, key, value), do: Keyword.put(attrs, key, value)

  defp validate_optional_agent_name(nil), do: :ok
  defp validate_optional_agent_name(agent_name), do: validate_agent_name(agent_name)

  defp validate_agent_name(agent_name) do
    if agent_name in AgentRunner.agent_names() do
      :ok
    else
      {:error,
       "unsupported agent #{inspect(agent_name)}; expected one of: #{Enum.join(AgentRunner.agent_names(), ", ")}"}
    end
  end

  defp validate_agent_transport(agent_transport) do
    if agent_transport in AgentRunner.agent_transports() do
      :ok
    else
      {:error,
       "unsupported agent transport #{inspect(agent_transport)}; expected one of: #{Enum.join(AgentRunner.agent_transports(), ", ")}"}
    end
  end

  defp start_app(opts) do
    case Keyword.fetch(opts, :start_app) do
      {:ok, start_app} -> start_app.()
      :error -> {:error, :missing_start_app_callback}
    end
  end

  defp workspace(opts), do: Keyword.get(opts, :workspace, Workspace)

  defp print_doctor_report(%{host: host, groups: groups}) do
    IO.puts("host #{host.name} (#{host.transport})")

    Enum.each(groups, fn group ->
      IO.puts("")
      IO.puts(group.name)
      Enum.each(group.checks, &print_doctor_check/1)
    end)
  end

  defp print_doctor_check(check) do
    IO.puts("  #{doctor_status(check.status)} #{check.name}#{doctor_detail(check.detail)}")
  end

  defp doctor_status(:ok), do: "OK"
  defp doctor_status(:fail), do: "FAIL"
  defp doctor_status(:skip), do: "SKIP"

  defp doctor_detail(nil), do: ""
  defp doctor_detail(""), do: ""
  defp doctor_detail(detail), do: " - #{detail}"

  defp print_hosts_doctor_report(report, json: true) do
    print_json(%{hosts_doctor: normalize_hosts_doctor(report)})
  end

  defp print_hosts_doctor_report(%{reports: reports}, json: false) do
    Enum.each(Enum.with_index(reports), fn {report, index} ->
      if index > 0, do: IO.puts("")
      print_doctor_report(report)
    end)
  end

  defp normalize_hosts_doctor(%{generated_at: generated_at, reports: reports}) do
    %{
      generated_at: generated_at,
      reports:
        Enum.map(reports, fn %{host: host, groups: groups} ->
          %{
            host: host.name,
            transport: host.transport,
            ssh_target: host.ssh_target || "",
            workspace_path: host.workspace_path,
            passed: HostDoctor.passed?(%{groups: groups}),
            groups: groups
          }
        end)
    }
  end

  # ---------------------------------------------------------------------------
  # Capacity helpers
  # ---------------------------------------------------------------------------

  defp capacity_opts(parsed) do
    profile = JX.HostCapacity.default_profile()

    profile =
      if parsed[:ram], do: Map.put(profile, :ram_mb_per_slot, parsed[:ram]), else: profile

    profile =
      if parsed[:disk], do: Map.put(profile, :disk_mb_per_slot, parsed[:disk]), else: profile

    profile =
      if parsed[:cpu], do: Map.put(profile, :cpu_cores_per_slot, parsed[:cpu]), else: profile

    [profile: profile]
  end

  defp print_capacity_result(%{error: reason} = r) do
    IO.puts("host #{r.host}: error - #{reason}")
  end

  defp print_capacity_result(%{host: name, resources: res, limits: lim, recommended_worktrees: rec, profile: prof}) do
    IO.puts("host #{name}")
    IO.puts("")
    IO.puts("  resources")
    IO.puts("    RAM   #{res.ram_available_mb} MB available / #{res.ram_total_mb} MB total")
    IO.puts("    disk  #{res.disk_available_mb} MB available / #{res.disk_total_mb} MB total")
    IO.puts("    CPU   #{res.cpu_cores} logical cores")
    IO.puts("")
    IO.puts("  profile: #{prof.name}")
    IO.puts("    #{prof.ram_mb_per_slot} MB RAM / #{prof.disk_mb_per_slot} MB disk / #{prof.cpu_cores_per_slot} CPU cores per slot")
    IO.puts("")
    IO.puts("  capacity")
    IO.puts("    by RAM   #{lim.by_ram} worktree(s)")
    IO.puts("    by disk  #{lim.by_disk} worktree(s)")
    IO.puts("    by CPU   #{lim.by_cpu} worktree(s)")
    IO.puts("")
    IO.puts("  recommended: #{rec} concurrent worktree(s)")
  end

  defp print_hosts_capacity_report(%{results: results}, json: true) do
    print_json(%{hosts_capacity: results})
  end

  defp print_hosts_capacity_report(%{results: results}, json: false) do
    Enum.each(Enum.with_index(results), fn {result, index} ->
      if index > 0, do: IO.puts("")
      print_capacity_result(result)
    end)
  end

  defp print_eval_result(%{verdict: :insufficient_data} = r) do
    IO.puts("host #{r.host}")
    IO.puts("")
    IO.puts("  verdict: insufficient data")
    IO.puts("  #{r.reasoning}")
  end

  defp print_eval_result(r) do
    limit_display = if r.current_limit, do: "#{r.current_limit}", else: "formula-derived"
    suggested = if r.suggested_limit, do: "  suggested limit: #{r.suggested_limit}", else: "  suggested limit: no change"

    IO.puts("host #{r.host}")
    IO.puts("")
    IO.puts("  observations analysed: #{r.observations_analysed}")
    IO.puts("  avg RAM headroom/slot: #{r.avg_headroom_per_slot} MB")

    if r.avg_load_ratio do
      IO.puts("  avg CPU load ratio:    #{r.avg_load_ratio}")
    end

    IO.puts("")
    IO.puts("  current limit: #{limit_display}")
    IO.puts("  verdict:       #{r.verdict}")
    IO.puts(suggested)
    IO.puts("")
    IO.puts("  #{r.reasoning}")
  end

  defp print_hosts_eval_report(%{results: results}, json: true) do
    print_json(%{hosts_capacity_eval: results})
  end

  defp print_hosts_eval_report(%{results: results}, json: false) do
    Enum.each(Enum.with_index(results), fn {result, index} ->
      if index > 0, do: IO.puts("")
      print_eval_result(result)
    end)
  end

  # ---------------------------------------------------------------------------

  defp print_hosts([]), do: IO.puts("no hosts")

  defp print_hosts(hosts) do
    rows =
      Enum.map(hosts, fn host ->
        [
          host.name,
          host.transport,
          host.ssh_target || "",
          host.workspace_path
        ]
      end)

    print_table(["HOST", "TRANSPORT", "SSH", "WORKSPACE"], rows)
  end
end
