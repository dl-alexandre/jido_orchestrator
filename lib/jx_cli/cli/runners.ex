defmodule JX.CLI.Runners do
  @moduledoc false

  alias JX.DelegatedExecution.Runner
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @runners_register_usage "jx runners register <runner-id> [--agent <agent-id>] [--host <host>] [--capability <cap>] [--workspace <id>] [--ttl-seconds 120] [--tmux-server <server>] [--tmux-session-prefix <prefix>] [--json]"
  @runners_heartbeat_usage "jx runners heartbeat <runner-id> [--session <id>] [--json]"
  @runners_ls_usage "jx runners ls [--status idle|busy|stale|disabled|all] [-n 50] [--json]"
  @runners_show_usage "jx runners show <runner-id> [--json]"

  def usage_lines do
    [
      @runners_register_usage,
      @runners_heartbeat_usage,
      @runners_ls_usage,
      @runners_show_usage
    ]
  end

  def usage do
    Enum.join(usage_lines(), " | ")
  end

  def run(["register", runner_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          agent: :string,
          host: :string,
          capability: :keep,
          workspace: :keep,
          ttl_seconds: :integer,
          tmux_server: :string,
          tmux_session_prefix: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @runners_register_usage),
         :ok <- validate_optional_positive("ttl-seconds", parsed[:ttl_seconds]),
         :ok <- start_app(opts),
         {:ok, runner} <-
           apply(workspace(opts), :register_runner, [
             %{
               runner_id: runner_id,
               agent_id: parsed[:agent] || "#{runner_id}:agent",
               host_name: parsed[:host] || "",
               capabilities: Keyword.get_values(parsed, :capability),
               workspace_affinity: Keyword.get_values(parsed, :workspace),
               heartbeat_ttl_seconds: parsed[:ttl_seconds] || 120,
               tmux_server: parsed[:tmux_server] || "jx",
               tmux_session_prefix: parsed[:tmux_session_prefix] || "jx-#{runner_id}"
             }
           ]) do
      print_runner("registered", runner, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["heartbeat", runner_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [session: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @runners_heartbeat_usage),
         :ok <- start_app(opts),
         {:ok, runner} <-
           apply(workspace(opts), :heartbeat_runner, [
             runner_id,
             [session_id: parsed[:session]]
           ]) do
      print_runner("heartbeat", runner, json: parsed[:json] || false)
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
         :ok <- expect_no_args(rest, @runners_ls_usage),
         :ok <- validate_optional_runner_status(parsed[:status]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:list_runners, [[status: parsed[:status], limit: limit]])
      |> print_runners(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["show", runner_id | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @runners_show_usage),
         :ok <- start_app(opts),
         runner when not is_nil(runner) <- apply(workspace(opts), :get_runner, [runner_id]) do
      print_runner("runner", runner, json: parsed[:json] || false)
      :ok
    else
      nil -> {:error, :runner_not_found}
      {:error, reason} -> {:error, reason}
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

  defp validate_optional_runner_status(nil), do: :ok

  defp validate_optional_runner_status(status)
       when status in ~w(idle busy stale disabled all),
       do: :ok

  defp validate_optional_runner_status(status),
    do:
      {:error,
       "unsupported runner status #{inspect(status)}; expected idle, busy, stale, disabled, or all"}

  defp print_runners(runners, opts) do
    packets = Enum.map(runners, &json_runner/1)

    if opts[:json] do
      print_json(%{runners: packets})
    else
      if packets == [] do
        IO.puts("no runners")
      else
        rows =
          Enum.map(packets, fn runner ->
            [
              runner.runner_id,
              runner.agent_id,
              runner.host_name,
              runner.status,
              Enum.join(runner.capabilities, ","),
              Enum.join(runner.workspace_affinity, ","),
              to_string(runner.active_sessions),
              format_time(runner.last_heartbeat_at)
            ]
          end)

        print_table(
          ["ID", "AGENT", "HOST", "STATUS", "CAPABILITIES", "WORKSPACES", "ACTIVE", "HEARTBEAT"],
          rows
        )
      end
    end
  end

  defp print_runner(label, runner, opts) do
    packet = json_runner(runner)

    if opts[:json] do
      print_json(packet)
    else
      IO.puts("#{label} #{packet.runner_id}")
      IO.puts("agent: #{packet.agent_id}")
      IO.puts("host: #{blank_to_dash(packet.host_name)}")
      IO.puts("status: #{packet.status}")
      IO.puts("capabilities: #{Enum.join(packet.capabilities, ",")}")
      IO.puts("workspace_affinity: #{Enum.join(packet.workspace_affinity, ",")}")
      IO.puts("tmux_server: #{blank_to_dash(packet.tmux_server)}")
      IO.puts("tmux_session_prefix: #{blank_to_dash(packet.tmux_session_prefix)}")
      IO.puts("last_heartbeat_at: #{format_time(packet.last_heartbeat_at)}")
    end
  end

  defp json_runner(%Runner{} = runner) do
    %{
      runner_id: runner.runner_id,
      agent_id: runner.agent_id,
      host_name: runner.host_name,
      status: runner.status,
      capabilities: decode_json_list(runner.capabilities),
      workspace_affinity: decode_json_list(runner.workspace_affinity),
      heartbeat_ttl_seconds: runner.heartbeat_ttl_seconds,
      last_heartbeat_at: runner.last_heartbeat_at,
      tmux_server: runner.tmux_server,
      tmux_session_prefix: runner.tmux_session_prefix
    }
  end

  defp json_runner(%{} = runner), do: runner

  defp decode_json_list(value) when is_list(value), do: Enum.map(value, &to_string/1)

  defp decode_json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> Enum.map(decoded, &to_string/1)
      _other -> []
    end
  end

  defp decode_json_list(_value), do: []

  defp blank_to_dash(value) when value in [nil, ""], do: "-"
  defp blank_to_dash(value), do: to_string(value)

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value) when is_binary(value), do: if(value == "", do: "-", else: value)
end
