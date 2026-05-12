defmodule JX.CLI.Agents do
  @moduledoc false

  alias JX.DelegatedExecution.Agent
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @agents_register_usage "jx agents register <agent-id> [--name <name>] [--capability <cap>] [--workspace <id>] [--ttl-seconds 120] [--json]"
  @agents_heartbeat_usage "jx agents heartbeat <agent-id> [--json]"
  @agents_ls_usage "jx agents ls [--status idle|busy|stale|disabled|all] [-n 50] [--json]"

  def usage_lines do
    [
      @agents_register_usage,
      @agents_heartbeat_usage,
      @agents_ls_usage
    ]
  end

  def usage do
    Enum.join(usage_lines(), " | ")
  end

  def run(["register", agent_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          name: :string,
          capability: :keep,
          workspace: :keep,
          ttl_seconds: :integer,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @agents_register_usage),
         :ok <- validate_optional_positive("ttl-seconds", parsed[:ttl_seconds]),
         :ok <- start_app(opts),
         {:ok, agent} <-
           apply(workspace(opts), :register_agent, [
             %{
               agent_id: agent_id,
               name: parsed[:name] || agent_id,
               capabilities: Keyword.get_values(parsed, :capability),
               workspace_affinity: Keyword.get_values(parsed, :workspace),
               heartbeat_ttl_seconds: parsed[:ttl_seconds] || 120
             }
           ]) do
      print_agent("registered", agent, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["heartbeat", agent_id | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @agents_heartbeat_usage),
         :ok <- start_app(opts),
         {:ok, agent} <- apply(workspace(opts), :heartbeat_agent, [agent_id]) do
      print_agent("heartbeat", agent, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["ls" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [status: :string, n: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @agents_ls_usage),
         :ok <- validate_optional_agent_status(parsed[:status]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:list_agents, [[status: parsed[:status], limit: limit]])
      |> print_agents(json: parsed[:json] || false)

      :ok
    end
  end

  def run(_args, _opts), do: {:error, "usage: #{usage()}"}

  defp workspace(opts), do: Keyword.get(opts, :workspace, Workspace)

  defp start_app(opts) do
    case Keyword.fetch(opts, :start_app) do
      {:ok, start_app} -> start_app.()
      :error -> {:error, :missing_start_app_callback}
    end
  end

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp validate_optional_positive(_name, nil), do: :ok
  defp validate_optional_positive(name, value), do: validate_positive(name, value)

  defp validate_optional_agent_status(nil), do: :ok

  defp validate_optional_agent_status(status)
       when status in ~w(idle busy stale disabled all),
       do: :ok

  defp validate_optional_agent_status(status),
    do:
      {:error,
       "unsupported agent status #{inspect(status)}; expected idle, busy, stale, disabled, or all"}

  defp print_agents(agents, opts) do
    if opts[:json] do
      print_json(%{agents: agents})
    else
      if agents == [] do
        IO.puts("no agents")
      else
        rows =
          Enum.map(agents, fn agent ->
            [
              agent.agent_id,
              agent.status,
              Enum.join(agent.capabilities, ","),
              Enum.join(agent.workspace_affinity, ","),
              to_string(agent.active_assignments),
              format_time(agent.last_heartbeat_at)
            ]
          end)

        print_table(["ID", "STATUS", "CAPABILITIES", "WORKSPACES", "ACTIVE", "HEARTBEAT"], rows)
      end
    end
  end

  defp print_agent(label, agent, opts) do
    packet = json_agent(agent)

    if opts[:json] do
      print_json(packet)
    else
      IO.puts("#{label} #{packet.agent_id}")
      IO.puts("status: #{packet.status}")
      IO.puts("capabilities: #{Enum.join(packet.capabilities, ",")}")
      IO.puts("workspace_affinity: #{Enum.join(packet.workspace_affinity, ",")}")
      IO.puts("last_heartbeat_at: #{format_time(packet.last_heartbeat_at)}")
    end
  end

  defp json_agent(%Agent{} = agent) do
    %{
      agent_id: agent.agent_id,
      name: agent.name,
      status: agent.status,
      capabilities: decode_json_list(agent.capabilities),
      workspace_affinity: decode_json_list(agent.workspace_affinity),
      heartbeat_ttl_seconds: agent.heartbeat_ttl_seconds,
      last_heartbeat_at: agent.last_heartbeat_at
    }
  end

  defp json_agent(%{} = agent), do: agent

  defp decode_json_list(value) when is_list(value), do: Enum.map(value, &to_string/1)

  defp decode_json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> Enum.map(decoded, &to_string/1)
      _other -> []
    end
  end

  defp decode_json_list(_value), do: []

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value) when is_binary(value), do: if(value == "", do: "-", else: value)
end
