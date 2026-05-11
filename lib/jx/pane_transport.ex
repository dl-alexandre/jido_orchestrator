defmodule JX.PaneTransport do
  @moduledoc """
  Read-only probes that execute through an already-open local tmux pane.
  """

  alias JX.SSHSessions
  alias JX.Shell
  alias JX.Tmux

  @default_timeout_ms 5_000
  @default_capture_lines 1_000

  def probe_ssh_sessions(sessions, opts \\ []) do
    sessions
    |> ssh_pane_candidates(opts)
    |> probe_ssh_candidates(opts)
  end

  def probe_ssh_candidates(candidates, opts \\ []) do
    Enum.map(candidates, &probe_ssh_session(&1, opts))
  end

  def ssh_pane_candidates(sessions, opts \\ []) do
    target = Keyword.get(opts, :target)

    sessions
    |> Enum.filter(&ssh_pane_candidate?/1)
    |> Enum.filter(&(is_nil(target) or &1.target == target))
    |> Enum.uniq_by(&{&1.server, &1.session, &1.window, &1.pane})
  end

  def probe(opts) do
    server = opts |> Keyword.get(:tmux_server, Tmux.managed_server()) |> Tmux.normalize_server()
    session_name = Keyword.fetch!(opts, :session_name)
    window = Keyword.get(opts, :window, 0)
    pane = Keyword.get(opts, :pane, 0)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    capture_lines = Keyword.get(opts, :capture_lines, @default_capture_lines)
    target = pane_target(session_name, window, pane)
    marker = marker()
    script = probe_script(marker)

    with :ok <- ensure_pane(server, target),
         :ok <- send_script(server, target, script, marker),
         {:ok, output} <-
           wait_for_marked_output(server, target, marker,
             timeout_ms: timeout_ms,
             capture_lines: capture_lines
           ) do
      probe =
        output
        |> SSHSessions.parse_probe_output()
        |> Map.merge(%{
          server: server,
          session: session_name,
          window: window,
          pane: pane,
          target: "#{server}/#{session_name}:#{window}.#{pane}"
        })

      {:ok, probe}
    end
  end

  defp probe_ssh_session(session, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    result =
      probe(
        tmux_server: session.server,
        session_name: session.session,
        window: session.window,
        pane: session.pane,
        timeout_ms: timeout_ms
      )

    case result do
      {:ok, probe} ->
        probe
        |> Map.merge(ssh_session_metadata(session))
        |> Map.put(:status, "ok")

      {:error, reason} ->
        session
        |> ssh_session_metadata()
        |> Map.merge(%{
          target: "#{session.server}/#{session.session}:#{session.window}.#{session.pane}",
          tmux: "unknown",
          sessions: 0,
          detail: "",
          status: "error",
          error: reason
        })
    end
  end

  defp send_script(server, target, script, marker) do
    delimiter = "__JX_SCRIPT_#{marker}__"
    lines = ["cat <<'#{delimiter}' | sh"] ++ script_lines(script) ++ [delimiter]

    Enum.reduce_while(lines, :ok, fn line, :ok ->
      case send_line(server, target, line) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp send_line(server, target, ""), do: send_enter(server, target)

  defp send_line(server, target, line) do
    with :ok <- send_literal(server, target, line) do
      send_enter(server, target)
    end
  end

  def parse_marked_output(output, marker) do
    lines = String.split(output, "\n", trim: false)
    start_marker = start_marker(marker)
    end_marker = end_marker(marker)

    with {:ok, start_index} <- find_line(lines, &(&1 == start_marker)),
         remaining = Enum.drop(lines, start_index + 1),
         {:ok, end_offset} <- find_line(remaining, &String.starts_with?(&1, end_marker <> ":")) do
      output =
        remaining
        |> Enum.take(end_offset)
        |> Enum.join("\n")

      {:ok, output}
    else
      :not_found -> :not_found
    end
  end

  defp ensure_pane(server, target) do
    case tmux(server, ["display-message", "-p", "-t", target, "\#{pane_id}"]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:pane_transport_failed, "pane", status, output}}
    end
  end

  defp send_literal(server, target, command) do
    case tmux(server, ["send-keys", "-t", target, "-l", "--", command]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:pane_transport_failed, "send", status, output}}
    end
  end

  defp send_enter(server, target) do
    case tmux(server, ["send-keys", "-t", target, "Enter"]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:pane_transport_failed, "enter", status, output}}
    end
  end

  defp wait_for_marked_output(server, target, marker, opts) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    capture_lines = Keyword.fetch!(opts, :capture_lines)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait_for_marked_output(server, target, marker, capture_lines, deadline, timeout_ms)
  end

  defp do_wait_for_marked_output(server, target, marker, capture_lines, deadline, timeout_ms) do
    case capture(server, target, capture_lines) do
      {:ok, output} ->
        case parse_marked_output(output, marker) do
          {:ok, marked_output} ->
            {:ok, marked_output}

          :not_found ->
            if System.monotonic_time(:millisecond) >= deadline do
              {:error, {:pane_probe_timeout, target, timeout_ms}}
            else
              Process.sleep(100)

              do_wait_for_marked_output(
                server,
                target,
                marker,
                capture_lines,
                deadline,
                timeout_ms
              )
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp capture(server, target, capture_lines) do
    case tmux(server, ["capture-pane", "-p", "-S", "-#{capture_lines}", "-t", target]) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:pane_transport_failed, "capture", status, output}}
    end
  end

  defp probe_script(marker) do
    """
    printf '%s\\n' #{Shell.quote(start_marker(marker))}
    printf 'can_execute\\tok\\n'

    if command -v tmux >/dev/null 2>&1; then
      printf 'tmux\\tok\\n'
    else
      printf 'tmux\\tmissing\\n'
      printf '%s:%s\\n' #{Shell.quote(end_marker(marker))} 0
      exit 0
    fi

    output=$(
    #{SSHSessions.remote_tmux_probe_script()}
    )

    printf '%s\\n' "$output" | while IFS= read -r line; do
      [ -n "$line" ] && printf 'session|%s\\n' "$line"
    done

    printf '%s:%s\\n' #{Shell.quote(end_marker(marker))} 0
    exit 0
    """
  end

  defp tmux(server, args) do
    System.cmd("tmux", Tmux.args(args, server), stderr_to_stdout: true)
  end

  defp pane_target(session_name, window, pane) do
    "#{Tmux.target(session_name)}:#{window}.#{pane}"
  end

  defp ssh_pane_candidate?(%{
         role: "outbound",
         server: server,
         session: session,
         window: window,
         pane: pane
       }) do
    server not in [nil, ""] and session not in [nil, ""] and is_integer(window) and
      is_integer(pane)
  end

  defp ssh_pane_candidate?(_session), do: false

  defp ssh_session_metadata(session) do
    %{
      ssh_target: session.target,
      registered_host: session.registered_host || "",
      pid: session.pid,
      server: session.server,
      session: session.session,
      window: session.window,
      pane: session.pane
    }
  end

  defp marker do
    6
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp find_line(lines, predicate) do
    case Enum.find_index(lines, predicate) do
      nil -> :not_found
      index -> {:ok, index}
    end
  end

  defp script_lines(script) do
    script
    |> String.trim_trailing("\n")
    |> String.split("\n", trim: false)
  end

  defp start_marker(marker), do: "__JX_START_#{marker}__"
  defp end_marker(marker), do: "__JX_END_#{marker}__"
end
