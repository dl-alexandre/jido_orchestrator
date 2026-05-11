defmodule JX.Tmux do
  @moduledoc """
  Builds remote tmux scripts for durable sessions.
  """

  alias JX.Shell

  @socket "jx"
  @server_pattern ~r/^[A-Za-z0-9._-]+$/

  def managed_server, do: @socket

  def valid_server?(server) do
    server = normalize_server(server)

    cond do
      server == "default" -> true
      String.starts_with?(server, "socket:") -> valid_socket_server?(server)
      true -> Regex.match?(@server_pattern, server)
    end
  end

  def normalize_server(nil), do: @socket
  def normalize_server(""), do: @socket
  def normalize_server(server), do: to_string(server)

  def command(server \\ @socket) do
    server = normalize_server(server)

    cond do
      server == "default" ->
        "tmux -L default"

      String.starts_with?(server, "socket:") ->
        "tmux -S #{socket_path_command(server)}"

      true ->
        "tmux -L #{Shell.quote(server)} -f /dev/null"
    end
  end

  def args(args, server \\ @socket) do
    server = normalize_server(server)

    cond do
      server == "default" -> ["-L", "default"] ++ args
      String.starts_with?(server, "socket:") -> ["-S", local_socket_path(server)] ++ args
      true -> ["-L", server, "-f", "/dev/null"] ++ args
    end
  end

  def target(session_name), do: "=" <> session_name

  def attach_command(session_name, server \\ @socket) do
    "#{command(server)} attach-session -t #{Shell.quote(target(session_name))}"
  end

  def list_sessions_script(server \\ @socket) do
    """
    #{command(server)} list-sessions -F '\#{session_name}\t\#{session_created}\t\#{session_attached}\t\#{session_windows}\t\#{pane_current_path}' 2>/dev/null || true
    """
  end

  def list_panes_script(server \\ @socket) do
    """
    #{command(server)} list-panes -a -F '\#{session_name}\t\#{window_index}\t\#{pane_index}\t\#{pane_id}\t\#{pane_active}\t\#{pane_tty}\t\#{pane_current_command}\t\#{pane_current_path}\t\#{pane_title}' 2>/dev/null || true
    """
  end

  def list_all_sessions_script do
    """
    echo jx-discover-tmux-all >/dev/null
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

    emit_sessions #{@socket} tmux -L #{@socket} -f /dev/null
    emit_sessions default tmux -L default

    socket_dir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
    if [ -d "$socket_dir" ]; then
      for socket in "$socket_dir"/*; do
        [ -S "$socket" ] || continue
        name=$(basename "$socket")

        case "$name" in
          #{@socket}|default) continue ;;
        esac

        emit_sessions "socket:$name" tmux -S "$socket"
      done
    fi
    """
  end

  def list_all_panes_script do
    """
    echo jx-discover-tmux-panes-all >/dev/null
    format='\#{session_name}\t\#{window_index}\t\#{pane_index}\t\#{pane_id}\t\#{pane_active}\t\#{pane_tty}\t\#{pane_current_command}\t\#{pane_current_path}\t\#{pane_title}'

    emit_panes() {
      server="$1"
      shift
      "$@" list-panes -a -F "$format" 2>/dev/null | while IFS= read -r line; do
        if [ -n "$line" ]; then
          printf '%s\t%s\n' "$server" "$line"
        fi
      done
    }

    emit_panes #{@socket} tmux -L #{@socket} -f /dev/null
    emit_panes default tmux -L default

    socket_dir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
    if [ -d "$socket_dir" ]; then
      for socket in "$socket_dir"/*; do
        [ -S "$socket" ] || continue
        name=$(basename "$socket")

        case "$name" in
          #{@socket}|default) continue ;;
        esac

        emit_panes "socket:$name" tmux -S "$socket"
      done
    fi
    """
  end

  def capture_pane_script(session_name, opts \\ []) do
    server = Keyword.get(opts, :tmux_server, @socket) |> normalize_server()
    window = Keyword.get(opts, :window, 0)
    pane = Keyword.get(opts, :pane, 0)
    lines = Keyword.get(opts, :lines, 80)
    target = Shell.quote("#{target(session_name)}:#{window}.#{pane}")

    """
    #{command(server)} capture-pane -p -S -#{lines} -t #{target}
    """
  end

  def send_keys_script(session_name, message, opts \\ []) do
    server = Keyword.get(opts, :tmux_server, @socket) |> normalize_server()
    window = Keyword.get(opts, :window, 0)
    pane = Keyword.get(opts, :pane, 0)
    enter? = Keyword.get(opts, :enter, true)
    session_target = Shell.quote(target(session_name))
    pane_target = Shell.quote("#{target(session_name)}:#{window}.#{pane}")
    message = Shell.quote(message)

    enter_command =
      if enter? do
        "#{command(server)} send-keys -t \"$pane_target\" Enter"
      else
        "true"
      end

    """
    echo jx-send-keys >/dev/null
    session_target=#{session_target}
    pane_target=#{pane_target}

    if ! #{command(server)} has-session -t "$session_target" 2>/dev/null; then
      echo "tmux session not found: $session_target" >&2
      exit 1
    fi

    #{command(server)} send-keys -t "$pane_target" -l -- #{message}
    #{enter_command}
    """
  end

  def send_key_tokens_script(session_name, keys, opts \\ []) do
    server = Keyword.get(opts, :tmux_server, @socket) |> normalize_server()
    window = Keyword.get(opts, :window, 0)
    pane = Keyword.get(opts, :pane, 0)
    enter? = Keyword.get(opts, :enter, true)
    session_target = Shell.quote(target(session_name))
    pane_target = Shell.quote("#{target(session_name)}:#{window}.#{pane}")

    keys =
      keys
      |> key_tokens(enter?)
      |> Enum.map_join(" ", &Shell.quote/1)

    """
    echo jx-send-key-tokens >/dev/null
    session_target=#{session_target}
    pane_target=#{pane_target}

    if ! #{command(server)} has-session -t "$session_target" 2>/dev/null; then
      echo "tmux session not found: $session_target" >&2
      exit 1
    fi

    #{command(server)} send-keys -t "$pane_target" -- #{keys}
    """
  end

  defp key_tokens(keys, enter?) do
    tokens =
      keys
      |> to_string()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(&normalize_key_token/1)

    if enter? do
      tokens ++ ["Enter"]
    else
      tokens
    end
  end

  defp normalize_key_token(token) do
    case String.downcase(token) do
      "enter" -> "Enter"
      "return" -> "Enter"
      "ret" -> "Enter"
      "esc" -> "Escape"
      "escape" -> "Escape"
      "tab" -> "Tab"
      "space" -> "Space"
      "backspace" -> "BSpace"
      "bspace" -> "BSpace"
      "delete" -> "DC"
      "del" -> "DC"
      "up" -> "Up"
      "down" -> "Down"
      "left" -> "Left"
      "right" -> "Right"
      "pageup" -> "PageUp"
      "pagedown" -> "PageDown"
      "home" -> "Home"
      "end" -> "End"
      <<"c-", rest::binary>> -> "C-#{rest}"
      <<"m-", rest::binary>> -> "M-#{rest}"
      _ -> token
    end
  end

  def inspect_session_script(session_name, worktree_path, server \\ @socket, opts \\ []) do
    window = Keyword.get(opts, :window, 0)
    pane = Keyword.get(opts, :pane, 0)
    target = Shell.quote(target(session_name))
    pane_target = Shell.quote("#{target(session_name)}:#{window}.#{pane}")
    worktree = Shell.quote(worktree_path)

    """
    echo jx-adopt-inspect >/dev/null
    target=#{target}
    pane_target=#{pane_target}
    worktree=#{worktree}

    if ! #{command(server)} has-session -t "$target" 2>/dev/null; then
      echo "tmux session not found: $target" >&2
      exit 1
    fi

    if ! #{command(server)} display-message -p -t "$pane_target" '\#{pane_id}' >/dev/null 2>&1; then
      echo "tmux pane not found: $pane_target" >&2
      exit 1
    fi

    if [ ! -d "$worktree" ]; then
      echo "worktree path does not exist: $worktree" >&2
      exit 1
    fi

    branch=$(git -C "$worktree" branch --show-current 2>/dev/null || true)
    if [ -z "$branch" ]; then branch=adopted; fi
    created=$(#{command(server)} display-message -p -t "$target" '\#{session_created}')
    attached=$(#{command(server)} display-message -p -t "$target" '\#{session_attached}')

    printf 'branch\t%s\n' "$branch"
    printf 'created\t%s\n' "$created"
    printf 'attached\t%s\n' "$attached"
    """
  end

  def ensure_session_script(task) do
    server = task_server(task)
    session_name = Shell.quote(task.session_name)
    target = Shell.quote(target(task.session_name))
    window = Map.get(task, :window, 0)
    pane = Map.get(task, :pane, 0)
    log_path = Shell.quote(task.log_path)
    worktree = Shell.quote(task.worktree_path)

    """
    session_name=#{session_name}
    target=#{target}
    worktree=#{worktree}

    if #{command(server)} has-session -t "$target" 2>/dev/null; then
      session_id=$(#{command(server)} display-message -p -t "$target" '\#{session_id}')
    else
      #{command(server)} new-session -d -s "$session_name" -c "$worktree" sh >/dev/null 2>&1
      session_id=$(#{command(server)} display-message -p -t "$target" '\#{session_id}')
    fi

    #{command(server)} pipe-pane -o -t "$session_id:#{window}.#{pane}" "cat >> #{log_path} 2>&1" </dev/null >/dev/null 2>&1 &
    """
  end

  def status_script(task) do
    server = task_server(task)
    target = Shell.quote(target(task.session_name))
    log_path = Shell.quote(task.log_path)
    exit_status = task.task_dir |> Path.join("exit_status") |> Shell.quote()

    """
    if #{command(server)} has-session -t #{target} 2>/dev/null; then echo running; else echo stopped; fi
    if [ -f #{log_path} ]; then
      if stat -c %Y #{log_path} >/dev/null 2>&1; then stat -c %Y #{log_path}; else stat -f %m #{log_path}; fi
    else
      echo 0
    fi
    if [ -f #{exit_status} ]; then cat #{exit_status}; else echo none; fi
    """
  end

  def stop_script(task) do
    stop_session_script(task.session_name, task_server(task))
  end

  def stop_session_script(session_name, server \\ @socket) do
    target = Shell.quote(target(session_name))

    """
    if #{command(server)} has-session -t #{target} 2>/dev/null; then
      #{command(server)} kill-session -t #{target}
    fi
    """
  end

  def adopt_session_script(task, task_json) do
    server = task_server(task)
    target = Shell.quote(target(task.session_name))
    window = Map.get(task, :window, 0)
    pane = Map.get(task, :pane, 0)
    task_dir = Shell.quote(task.task_dir)
    prompt = Shell.quote(task.prompt)
    task_json = Shell.quote(task_json)
    log_path = Shell.quote(task.log_path)

    """
    set -eu
    echo jx-adopt-session >/dev/null
    target=#{target}
    task_dir=#{task_dir}

    if ! #{command(server)} has-session -t "$target" 2>/dev/null; then
      echo "tmux session not found: $target" >&2
      exit 1
    fi

    mkdir -p "$task_dir/artifacts"
    printf %s #{prompt} > "$task_dir/prompt.md"
    printf %s #{task_json} > "$task_dir/task.json"
    touch #{log_path}

    session_id=$(#{command(server)} display-message -p -t "$target" '\#{session_id}')
    #{command(server)} pipe-pane -o -t "$session_id:#{window}.#{pane}" "cat >> #{log_path} 2>&1" </dev/null >/dev/null 2>&1 &
    """
  end

  defp task_server(task) do
    task
    |> Map.get(:tmux_server)
    |> normalize_server()
  end

  defp valid_socket_server?("socket:" <> name), do: Regex.match?(@server_pattern, name)
  defp valid_socket_server?(_server), do: false

  defp socket_path_command("socket:" <> name) do
    "\"${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/\"#{Shell.quote(name)}"
  end

  defp local_socket_path("socket:" <> name) do
    tmp_dir = System.get_env("TMUX_TMPDIR") || "/tmp"
    uid = System.cmd("id", ["-u"]) |> elem(0) |> String.trim()

    Path.join([tmp_dir, "tmux-#{uid}", name])
  end
end
