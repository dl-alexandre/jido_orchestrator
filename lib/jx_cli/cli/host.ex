defmodule JX.CLI.Host do
  @moduledoc false

  alias JX.AgentRunner
  alias JX.HostDoctor
  alias JX.Workspace

  @host_doctor_usage "jx host doctor <host> [--agent claude|opencode|codex] [--transport native|acpx]"
  @host_add_usage "jx host add <name> (--ssh <user@host> | --local) --workspace <path>"
  @hosts_doctor_usage "jx hosts doctor [--agent claude|opencode|codex] [--transport native|acpx] [--json]"

  def usage_lines(:host), do: [@host_add_usage, "jx host ls", @host_doctor_usage]
  def usage_lines(:hosts), do: [@hosts_doctor_usage]

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

  def run(["doctor" | _args], _opts), do: {:error, "usage: #{@host_doctor_usage}"}
  def run(_args, _opts), do: {:error, "usage: #{@host_add_usage} | #{@host_doctor_usage}"}

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

  defp validate_options([]), do: :ok
  defp validate_options(invalid), do: {:error, "invalid options: #{inspect(invalid)}"}

  defp expect_no_args([], _usage), do: :ok
  defp expect_no_args(_args, usage), do: {:error, "usage: #{usage}"}

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

  defp print_json(data) do
    data
    |> Jason.encode!(pretty: true)
    |> IO.puts()
  end

  defp print_table(headers, rows) do
    widths =
      [headers | rows]
      |> Enum.zip()
      |> Enum.map(fn column ->
        column
        |> Tuple.to_list()
        |> Enum.map(&String.length/1)
        |> Enum.max()
      end)

    print_row(headers, widths)
    Enum.each(rows, &print_row(&1, widths))
  end

  defp print_row(row, widths) do
    row
    |> Enum.zip(widths)
    |> Enum.map(fn {value, width} -> String.pad_trailing(value, width + 2) end)
    |> IO.puts()
  end
end
