defmodule JX.CLI.SSH do
  @moduledoc false

  alias JX.PaneTransport
  alias JX.SSHSessions
  alias JX.Tmux
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_table: 2, validate_options: 1]

  @ls_usage "jx ssh ls"
  @probe_usage "jx ssh probe [--target <target>]"
  @pane_probe_usage "jx ssh pane-probe --all [--target <ssh-target>] [--dry-run] [--timeout-ms 5000] | jx ssh pane-probe --session <name> [--server <server>] [--window 0] [--pane 0] [--timeout-ms 5000]"

  def usage_lines do
    [
      @ls_usage,
      @probe_usage,
      @pane_probe_usage
    ]
  end

  def usage, do: Enum.join(usage_lines(), " | ")

  def run(["ls"], opts) do
    with :ok <- start_app(opts),
         {:ok, sessions} <-
           apply(ssh_sessions(opts), :list, [apply(workspace(opts), :list_hosts, [])]) do
      print_ssh_sessions(sessions)
      :ok
    end
  end

  def run(["probe" | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [target: :string])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @probe_usage),
         {:ok, targets} <- ssh_probe_targets(opts, parsed[:target]),
         {:ok, probes} <- apply(ssh_sessions(opts), :probe, [targets]) do
      print_ssh_probes(probes)
      :ok
    end
  end

  def run(["pane-probe" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          all: :boolean,
          target: :string,
          dry_run: :boolean,
          server: :string,
          session: :string,
          window: :integer,
          pane: :integer,
          timeout_ms: :integer
        ]
      )

    server = parsed[:server] || Tmux.managed_server()
    window = parsed[:window] || 0
    pane = parsed[:pane] || 0
    timeout_ms = parsed[:timeout_ms] || 5_000

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @pane_probe_usage),
         :ok <- validate_non_negative("window", window),
         :ok <- validate_non_negative("pane", pane),
         :ok <- validate_positive("timeout-ms", timeout_ms) do
      if parsed[:all] do
        run_ssh_pane_probe_all(opts, parsed[:target], timeout_ms, parsed[:dry_run] || false)
      else
        run_ssh_pane_probe_one(opts, parsed, server, window, pane, timeout_ms)
      end
    end
  end

  def run(_args, _opts), do: {:error, "usage: #{usage()}"}

  defp workspace(opts), do: Keyword.get(opts, :workspace, Workspace)
  defp ssh_sessions(opts), do: Keyword.get(opts, :ssh_sessions, SSHSessions)
  defp pane_transport(opts), do: Keyword.get(opts, :pane_transport, PaneTransport)

  defp start_app(opts) do
    case Keyword.fetch(opts, :start_app) do
      {:ok, start_app} -> start_app.()
      :error -> {:error, :missing_start_app_callback}
    end
  end

  defp ssh_probe_targets(opts, nil), do: apply(ssh_sessions(opts), :active_targets, [])
  defp ssh_probe_targets(_opts, target), do: {:ok, [target]}

  defp run_ssh_pane_probe_all(opts, target, timeout_ms, dry_run?) do
    with :ok <- start_app(opts),
         {:ok, sessions} <-
           apply(ssh_sessions(opts), :list, [apply(workspace(opts), :list_hosts, [])]) do
      if dry_run? do
        sessions
        |> then(&apply(pane_transport(opts), :ssh_pane_candidates, [&1, [target: target]]))
        |> print_pane_probe_candidates()
      else
        sessions
        |> then(
          &apply(pane_transport(opts), :probe_ssh_sessions, [
            &1,
            [target: target, timeout_ms: timeout_ms]
          ])
        )
        |> print_pane_probe_scan()
      end

      :ok
    end
  end

  defp run_ssh_pane_probe_one(opts, parsed, server, window, pane, timeout_ms) do
    with :ok <- validate_tmux_server(server),
         {:ok, session_name} <- required_option(parsed, :session, @pane_probe_usage),
         {:ok, probe} <-
           apply(pane_transport(opts), :probe, [
             [
               session_name: session_name,
               tmux_server: server,
               window: window,
               pane: pane,
               timeout_ms: timeout_ms
             ]
           ]) do
      print_pane_probe(probe)
      :ok
    end
  end

  defp validate_tmux_server(server) do
    if Tmux.valid_server?(server) do
      :ok
    else
      {:error,
       "invalid tmux server #{inspect(server)}; use default, #{Tmux.managed_server()}, socket:<name>, or a tmux -L name"}
    end
  end

  defp validate_non_negative(_name, value) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative(name, _value), do: {:error, "#{name} must be a non-negative integer"}

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp required_option(opts, key, usage) do
    case opts[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, "usage: #{usage}"}
    end
  end

  defp print_ssh_sessions([]), do: IO.puts("no ssh sessions")

  defp print_ssh_sessions(sessions) do
    rows =
      Enum.map(sessions, fn session ->
        [
          session.role,
          Integer.to_string(session.pid),
          session.stat,
          session.tty,
          session.target,
          session.registered_host,
          session.server,
          session.session,
          format_optional_integer(session.window),
          format_optional_integer(session.pane),
          truncate(session.current_path, 72),
          truncate(session.title, 48),
          truncate(session.command, 96)
        ]
      end)

    print_table(
      [
        "ROLE",
        "PID",
        "STAT",
        "TTY",
        "TARGET",
        "HOST",
        "SERVER",
        "SESSION",
        "WIN",
        "PANE",
        "PATH",
        "TITLE",
        "COMMAND"
      ],
      rows
    )
  end

  defp print_ssh_probes([]), do: IO.puts("no ssh targets")

  defp print_ssh_probes(probes) do
    rows =
      Enum.map(probes, fn probe ->
        [
          probe.target,
          probe.ssh,
          probe.tmux,
          Integer.to_string(probe.sessions),
          truncate(Map.get(probe, :detail, ""), 120)
        ]
      end)

    print_table(["TARGET", "SSH", "TMUX", "SESSIONS", "DETAIL"], rows)
  end

  defp print_pane_probe(probe) do
    print_table(
      ["PANE", "TMUX", "SESSIONS", "DETAIL"],
      [
        [
          probe.target,
          probe.tmux,
          Integer.to_string(probe.sessions),
          truncate(pane_probe_detail(probe), 120)
        ]
      ]
    )
  end

  defp print_pane_probe_scan([]), do: IO.puts("no ssh panes")

  defp print_pane_probe_scan(probes) do
    rows =
      Enum.map(probes, fn probe ->
        [
          probe.ssh_target,
          probe.registered_host,
          Integer.to_string(probe.pid),
          probe.target,
          probe.status,
          probe.tmux,
          Integer.to_string(probe.sessions),
          truncate(pane_probe_detail(probe), 120)
        ]
      end)

    print_table(
      ["SSH_TARGET", "HOST", "PID", "PANE", "STATUS", "TMUX", "SESSIONS", "DETAIL"],
      rows
    )
  end

  defp print_pane_probe_candidates([]), do: IO.puts("no ssh panes")

  defp print_pane_probe_candidates(candidates) do
    rows =
      Enum.map(candidates, fn candidate ->
        [
          candidate.target,
          candidate.registered_host,
          Integer.to_string(candidate.pid),
          "#{candidate.server}/#{candidate.session}:#{candidate.window}.#{candidate.pane}",
          truncate(candidate.current_path, 88),
          truncate(candidate.title, 56)
        ]
      end)

    print_table(["SSH_TARGET", "HOST", "PID", "PANE", "PATH", "TITLE"], rows)
  end

  defp pane_probe_detail(%{error: reason}), do: format_error(reason)

  defp pane_probe_detail(%{remote_sessions: sessions}) when sessions != [] do
    sessions
    |> Enum.map(&remote_session_summary/1)
    |> Enum.join("; ")
  end

  defp pane_probe_detail(probe), do: Map.get(probe, :detail, "")

  defp remote_session_summary(session) do
    path = Map.get(session, :current_path, "")
    windows = Map.get(session, :windows, 0)
    attached = Map.get(session, :attached, 0)

    "#{session.server}/#{session.session} windows=#{windows} attached=#{attached} path=#{path}"
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp format_optional_integer(nil), do: ""
  defp format_optional_integer(integer), do: Integer.to_string(integer)

  defp truncate(value, max_length) do
    value = value || ""

    if String.length(value) > max_length do
      String.slice(value, 0, max_length - 3) <> "..."
    else
      value
    end
  end
end
