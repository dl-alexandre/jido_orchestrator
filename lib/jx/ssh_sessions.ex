defmodule JX.SSHSessions do
  @moduledoc """
  Read-only inventory of local SSH processes and their tmux pane context.
  """

  alias JX.ProcessInventory
  alias JX.Shell
  alias JX.Tmux

  @ssh_option_args ~w(
    -B -b -c -D -E -e -F -I -i -J -L -l -m -O -o -p -Q -R -S -W -w
  )
  @ssh_probe_options ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]

  def list(registered_hosts \\ []) do
    with {:ok, processes} <- ProcessInventory.list(kinds: ~w(ssh sshd), all: true),
         {:ok, panes} <- local_tmux_panes() do
      panes_by_tty = Map.new(panes, &{normalize_tty(&1.tty), &1})

      sessions =
        processes
        |> Enum.map(&session(&1, panes_by_tty, registered_hosts))
        |> Enum.sort_by(&{&1.tty, &1.pid})

      {:ok, sessions}
    end
  end

  def active_targets do
    with {:ok, sessions} <- list() do
      targets =
        sessions
        |> Enum.filter(&(&1.role == "outbound"))
        |> Enum.map(& &1.target)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      {:ok, targets}
    end
  end

  def probe(targets) when is_list(targets) do
    {:ok, Enum.map(targets, &probe_target/1)}
  end

  def probe_target(target) do
    case System.cmd("ssh", @ssh_probe_options ++ [target, remote_probe_command()],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> parse_probe_output()
        |> Map.put(:target, target)
        |> Map.put(:ssh, "ok")

      {output, status} ->
        %{
          target: target,
          ssh: "failed",
          tmux: "unknown",
          sessions: 0,
          remote_sessions: [],
          detail: String.trim(output),
          exit_status: status
        }
    end
  end

  def parse_probe_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(
      %{tmux: "unknown", sessions: 0, remote_sessions: [], detail: ""},
      &parse_probe_line/2
    )
  end

  def parse_target(command) do
    command = String.trim(command)
    executable = command |> String.split(~r/\s+/, parts: 2) |> hd() |> Path.basename()

    cond do
      executable == "ssh" ->
        command
        |> split_command()
        |> Enum.drop(1)
        |> ssh_target_from_args()

      executable == "sshs" ->
        ""

      String.starts_with?(executable, "sshd") ->
        parse_sshd_target(command)

      true ->
        ""
    end
  end

  defp remote_probe_command do
    script = """
    printf 'can_execute\tok\n'

    if command -v tmux >/dev/null 2>&1; then
      printf 'tmux\tok\n'
    else
      printf 'tmux\tmissing\n'
      exit 0
    fi

    output=$(
    #{remote_tmux_probe_script()}
    )

    printf '%s\n' "$output" | while IFS= read -r line; do
      [ -n "$line" ] && printf 'session|%s\n' "$line"
    done

    exit 0
    """

    "sh -lc #{Shell.quote(script)}"
  end

  def remote_tmux_all_script do
    """
    format='\#{session_name}\t\#{session_created}\t\#{session_attached}\t\#{session_windows}\t\#{pane_current_path}'

    emit_sessions() {
      server="$1"
      shift
      "$@" list-sessions -F "$format" 2>/dev/null | while IFS= read -r line; do
        if [ -n "$line" ]; then
          printf '%s\t%s\n' "$server" "$line"
        fi
      done
    }

    emit_sessions jx tmux -L jx -f /dev/null
    emit_sessions default tmux -L default

    socket_dir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
    if [ -d "$socket_dir" ]; then
      for socket in "$socket_dir"/*; do
        [ -S "$socket" ] || continue
        name=$(basename "$socket")

        if [ "$name" = "jx" ] || [ "$name" = "default" ]; then
          continue
        fi

        emit_sessions "socket:$name" tmux -S "$socket"
      done
    fi
    """
  end

  def remote_tmux_probe_script do
    """
    format='\#{session_name}|\#{session_created}|\#{session_attached}|\#{session_windows}|\#{pane_current_path}'

    emit_sessions() {
      server="$1"
      shift
      "$@" list-sessions -F "$format" 2>/dev/null | while IFS= read -r line; do
        if [ -n "$line" ]; then
          printf '%s|%s\n' "$server" "$line"
        fi
      done
    }

    emit_sessions jx tmux -L jx -f /dev/null
    emit_sessions default tmux -L default

    socket_dir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
    if [ -d "$socket_dir" ]; then
      for socket in "$socket_dir"/*; do
        [ -S "$socket" ] || continue
        name=$(basename "$socket")

        if [ "$name" = "jx" ] || [ "$name" = "default" ]; then
          continue
        fi

        emit_sessions "socket:$name" tmux -S "$socket"
      done
    fi
    """
  end

  defp parse_probe_line(line, probe) do
    cond do
      String.starts_with?(line, "tmux_sessions_error\t") ->
        detail = String.replace_prefix(line, "tmux_sessions_error\t", "")
        %{probe | detail: detail}

      String.starts_with?(line, "tmux\t") ->
        tmux_status = String.replace_prefix(line, "tmux\t", "")
        %{probe | tmux: tmux_status}

      match = Regex.run(~r/^tmux\s+(.+)$/, line) ->
        [_line, tmux_status] = match
        %{probe | tmux: tmux_status}

      String.starts_with?(line, "session\t") ->
        line
        |> String.replace_prefix("session\t", "")
        |> record_remote_session(probe)

      String.starts_with?(line, "session|") ->
        line
        |> String.replace_prefix("session|", "")
        |> record_remote_session(probe)

      Regex.match?(~r/^session\s+/, line) ->
        %{probe | sessions: probe.sessions + 1}

      true ->
        probe
    end
  end

  defp record_remote_session(line, probe) do
    case parse_remote_session(line) do
      nil ->
        %{probe | sessions: probe.sessions + 1}

      session ->
        %{
          probe
          | sessions: probe.sessions + 1,
            remote_sessions: probe.remote_sessions ++ [session]
        }
    end
  end

  defp parse_remote_session(line) do
    case String.split(line, "|", parts: 6) do
      [server, session, created, attached, windows, current_path] ->
        %{
          server: server,
          session: session,
          created: parse_integer(created),
          attached: parse_integer(attached) || 0,
          windows: parse_integer(windows) || 0,
          current_path: current_path
        }

      _other ->
        nil
    end
  end

  defp session(process, panes_by_tty, registered_hosts) do
    pane = Map.get(panes_by_tty, normalize_tty(process.tty))
    target = parse_target(process.command)

    %{
      role: role(process.command),
      pid: process.pid,
      ppid: process.ppid,
      stat: process.stat,
      active: foreground?(process.stat),
      tty: process.tty,
      target: target,
      registered_host: registered_host(target, registered_hosts),
      command: process.command,
      server: (pane && pane.server) || "",
      session: (pane && pane.session) || "",
      window: pane && pane.window,
      pane: pane && pane.pane,
      current_path: (pane && pane.current_path) || "",
      title: (pane && pane.title) || ""
    }
  end

  defp role(command) do
    executable =
      command
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> hd()
      |> Path.basename()

    cond do
      executable == "ssh" -> "outbound"
      executable == "sshs" -> "helper"
      String.starts_with?(executable, "sshd") -> "inbound"
      true -> "unknown"
    end
  end

  defp foreground?(stat) when is_binary(stat), do: String.contains?(stat, "+")
  defp foreground?(_stat), do: false

  defp registered_host("", _hosts), do: ""

  defp registered_host(target, hosts) do
    case Enum.find(hosts, &host_matches_target?(&1, target)) do
      nil -> ""
      host -> host.name
    end
  end

  defp host_matches_target?(host, target) do
    target in [host.name, host.ssh_target]
  end

  defp split_command(command) do
    String.split(command, ~r/\s+/, trim: true)
  end

  defp ssh_target_from_args([]), do: ""

  defp ssh_target_from_args([arg | rest]) do
    cond do
      arg in @ssh_option_args ->
        rest |> Enum.drop(1) |> ssh_target_from_args()

      String.starts_with?(arg, "-") ->
        ssh_target_from_args(rest)

      true ->
        arg
    end
  end

  defp parse_sshd_target(command) do
    case String.split(command, ":", parts: 2) do
      [_prefix, target] ->
        target
        |> String.trim()
        |> String.replace(~r/\s+\[.*\]$/, "")

      _no_match ->
        ""
    end
  end

  defp local_tmux_panes do
    case System.cmd("sh", ["-lc", Tmux.list_all_panes_script()], stderr_to_stdout: true) do
      {output, 0} -> {:ok, parse_tmux_panes(output)}
      {output, status} -> {:error, {:tmux_inventory_failed, status, output}}
    end
  end

  defp parse_tmux_panes(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_tmux_pane/1)
  end

  defp parse_tmux_pane(line) do
    case String.split(line, "\t", parts: 10) do
      [server, session, window, pane, _pane_id, _active, tty, _command, current_path, title] ->
        [
          %{
            server: server,
            session: session,
            window: parse_integer(window) || 0,
            pane: parse_integer(pane) || 0,
            tty: tty,
            current_path: current_path,
            title: title
          }
        ]

      _invalid ->
        []
    end
  end

  defp normalize_tty(nil), do: ""

  defp normalize_tty(tty) do
    tty
    |> String.trim()
    |> String.replace_prefix("/dev/", "")
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end
end
