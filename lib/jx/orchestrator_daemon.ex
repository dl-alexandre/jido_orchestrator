defmodule JX.OrchestratorDaemon do
  @moduledoc """
  Runs the orchestration loop in a detached tmux session.

  The foreground CLI stays useful for strategy and inspection while this process
  continuously observes managed panes, advances chambered prompts, and records
  events in the shared database.
  """

  alias JX.Shell
  alias JX.ResourceOwnerships
  alias JX.Tmux

  @default_session_name "jx-orchestrator"
  @default_interval_ms 15_000
  @default_lines 160
  @default_scan_limit 100
  @default_queue_limit 10
  @default_event_limit 50
  @default_decision_limit 20
  @default_min_observe_age_seconds 15
  @session_pattern ~r/^[A-Za-z0-9._-]+$/

  def default_session_name, do: @default_session_name

  def default_log_path(session_name \\ @default_session_name) do
    Path.expand("~/.jx/logs/#{session_name}.log")
  end

  def start(opts \\ []) do
    daemon = daemon_opts(opts)

    with :ok <- validate(daemon),
         :ok <- File.mkdir_p(Path.dirname(daemon.log_path)),
         :ok <- touch_log(daemon),
         {:ok, current} <- status(daemon),
         :ok <- maybe_replace_existing(current, daemon),
         {:ok, _started} <- start_tmux_session(daemon),
         :ok <- register_daemon_resource(daemon),
         {:ok, started} <- status(daemon) do
      {:ok, Map.merge(started, %{started: true, command: loop_command(daemon)})}
    end
  end

  def status(opts \\ []) do
    daemon = daemon_opts(opts)

    with :ok <- validate(daemon) do
      case tmux(daemon, ["has-session", "-t", Tmux.target(daemon.session_name)]) do
        {_output, 0} ->
          {:ok, running_status(daemon)}

        {_output, _status} ->
          {:ok, base_status(daemon)}
      end
    end
  end

  def stop(opts \\ []) do
    daemon = daemon_opts(opts)

    with :ok <- validate(daemon),
         {:ok, current} <- status(daemon) do
      if current.running do
        case tmux(daemon, ["kill-session", "-t", Tmux.target(daemon.session_name)]) do
          {_output, 0} ->
            {:ok, Map.merge(current, %{running: false, stopped: true})}

          {output, status} ->
            {:error, {:orchestrator_tmux_failed, status, String.trim(output)}}
        end
      else
        {:ok, Map.put(current, :stopped, false)}
      end
    end
  end

  def logs(opts \\ []) do
    daemon = daemon_opts(opts)
    lines = Keyword.get(opts, :lines, 80)

    with :ok <- validate(daemon),
         {:ok, current} <- status(daemon) do
      output =
        case File.read(daemon.log_path) do
          {:ok, contents} ->
            tail_lines(contents, lines)

          {:error, :enoent} ->
            ""

          {:error, reason} ->
            raise File.Error, reason: reason, action: "read", path: daemon.log_path
        end

      {:ok,
       current
       |> Map.merge(%{lines: lines, output: output})}
    end
  rescue
    error in File.Error -> {:error, {:orchestrator_log_failed, error.reason, error.path}}
  end

  def loop_command(opts \\ []) do
    daemon = daemon_opts(opts)
    env = daemon_env(daemon)

    command =
      ["exec", "env"]
      |> Kernel.++(env)
      |> Kernel.++([daemon.cli_path | orchestrate_args(daemon)])
      |> Enum.map(&Shell.quote/1)
      |> Enum.join(" ")

    command <> " >> " <> Shell.quote(daemon.log_path) <> " 2>&1"
  end

  def orchestrate_args(opts \\ []) do
    daemon = daemon_opts(opts)

    ["orchestrate", "run"]
    |> put_option("--consumer", daemon.consumer)
    |> put_option("--host", daemon.host_name)
    |> put_flag("--managed", daemon.all_tmux == false)
    |> put_flag("--all-processes", daemon.all_processes)
    |> put_option("--type", daemon.type)
    |> put_option("--ssh-target", daemon.ssh_target)
    |> put_option("--work-state", daemon.work_state)
    |> put_option("--control", daemon.control_mode)
    |> put_option("--prompt-status", daemon.prompt_status)
    |> put_flag("--no-observe", daemon.observe == false)
    |> put_option("--lines", daemon.lines)
    |> put_option("--scan-limit", daemon.scan_limit)
    |> put_option("--queue-limit", daemon.queue_limit)
    |> put_option("--event-limit", daemon.event_limit)
    |> put_option("--decision-limit", daemon.decision_limit)
    |> put_option("--min-observe-age-seconds", daemon.min_observe_age_seconds)
    |> put_option("--interval-ms", daemon.interval_ms)
    |> put_option("--iterations", 0)
    |> put_flag("--execute", daemon.execute)
    |> put_flag("--yes", daemon.yes)
    |> put_ack_flag(daemon.ack)
    |> put_flag("--auto-plan", daemon.auto_plan)
    |> put_flag("--no-enter", daemon.enter == false)
  end

  defp daemon_opts(%{} = opts), do: daemon_opts(Map.to_list(opts))

  defp daemon_opts(opts) do
    cwd = Keyword.get(opts, :cwd) || File.cwd!()
    session_name = Keyword.get(opts, :session_name) || Keyword.get(opts, :session)
    session_name = session_name || @default_session_name
    dry_run? = Keyword.get(opts, :dry_run, false)

    %{
      session_name: session_name,
      tmux_server:
        Keyword.get(opts, :tmux_server) || Keyword.get(opts, :server) || Tmux.managed_server(),
      log_path:
        Keyword.get(opts, :log_path) || Keyword.get(opts, :log) || default_log_path(session_name),
      cwd: cwd,
      cli_path: Keyword.get(opts, :cli_path) || default_cli_path(cwd),
      db_path: Keyword.get(opts, :db_path),
      consumer: Keyword.get(opts, :consumer),
      host_name: Keyword.get(opts, :host_name),
      all_tmux: Keyword.get(opts, :all_tmux, true),
      all_processes: Keyword.get(opts, :all_processes, false),
      type: Keyword.get(opts, :type),
      ssh_target: Keyword.get(opts, :ssh_target),
      work_state: Keyword.get(opts, :work_state),
      control_mode: Keyword.get(opts, :control_mode),
      prompt_status: Keyword.get(opts, :prompt_status),
      observe: Keyword.get(opts, :observe, true),
      lines: Keyword.get(opts, :lines, @default_lines),
      scan_limit: Keyword.get(opts, :scan_limit, @default_scan_limit),
      queue_limit: Keyword.get(opts, :queue_limit, @default_queue_limit),
      event_limit: Keyword.get(opts, :event_limit, @default_event_limit),
      decision_limit: Keyword.get(opts, :decision_limit, @default_decision_limit),
      min_observe_age_seconds:
        Keyword.get(opts, :min_observe_age_seconds, @default_min_observe_age_seconds),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      execute: if(dry_run?, do: false, else: Keyword.get(opts, :execute, true)),
      yes: if(dry_run?, do: false, else: Keyword.get(opts, :yes, true)),
      ack: if(dry_run?, do: false, else: Keyword.get(opts, :ack, true)),
      auto_plan: Keyword.get(opts, :auto_plan, true),
      enter: Keyword.get(opts, :enter, true),
      replace: Keyword.get(opts, :replace, false)
    }
  end

  defp validate(%{session_name: session_name, tmux_server: tmux_server}) do
    cond do
      not Regex.match?(@session_pattern, session_name) ->
        {:error, {:invalid_orchestrator_session, session_name}}

      not Tmux.valid_server?(tmux_server) ->
        {:error, {:invalid_tmux_server, tmux_server}}

      true ->
        :ok
    end
  end

  defp touch_log(daemon) do
    line = "[#{DateTime.utc_now() |> DateTime.to_iso8601()}] starting #{daemon.session_name}\n"
    File.write(daemon.log_path, line, [:append])
  end

  defp maybe_replace_existing(%{running: false}, _daemon), do: :ok

  defp maybe_replace_existing(%{running: true}, %{replace: true} = daemon) do
    case stop(daemon) do
      {:ok, _stopped} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp maybe_replace_existing(current, _daemon),
    do: {:error, {:orchestrator_already_running, current}}

  defp start_tmux_session(daemon) do
    case tmux(daemon, [
           "new-session",
           "-d",
           "-s",
           daemon.session_name,
           "-c",
           daemon.cwd,
           loop_command(daemon)
         ]) do
      {_output, 0} -> {:ok, :started}
      {output, status} -> {:error, {:orchestrator_tmux_failed, status, String.trim(output)}}
    end
  end

  defp register_daemon_resource(daemon) do
    attrs = %{
      owner_type: "orchestrator_daemon",
      owner_project: daemon.consumer || "orchestrator",
      resource_type: "tmux_session",
      resource_name: daemon.session_name,
      tmux_server: daemon.tmux_server,
      cleanup_policy: "kill_tmux_session",
      reason: "orchestrator daemon tmux session",
      metadata:
        Jason.encode!(%{
          purpose: "run jx orchestrate loop",
          consumer: daemon.consumer,
          host_name: daemon.host_name,
          workspace: daemon.cwd,
          log_path: daemon.log_path,
          db_path: daemon.db_path,
          cli_path: daemon.cli_path
        })
    }

    case resource_ownerships().register_tmux_session(attrs) do
      {:ok, _resource} ->
        :ok

      {:error, reason} ->
        _ = tmux(daemon, ["kill-session", "-t", Tmux.target(daemon.session_name)])
        {:error, {:orchestrator_resource_registration_failed, reason}}
    end
  end

  defp resource_ownerships do
    Application.get_env(:jx, :resource_ownerships, ResourceOwnerships)
  end

  defp running_status(daemon) do
    format =
      "\#{session_created}\t\#{session_attached}\t\#{pane_pid}\t\#{pane_current_command}\t\#{pane_current_path}"

    details =
      case tmux(daemon, ["list-panes", "-t", Tmux.target(daemon.session_name), "-F", format]) do
        {output, 0} -> parse_status_details(output)
        {_output, _status} -> %{}
      end

    daemon
    |> base_status()
    |> Map.merge(%{running: true})
    |> Map.merge(details)
  end

  defp base_status(daemon) do
    %{
      running: false,
      session_name: daemon.session_name,
      tmux_server: daemon.tmux_server,
      log_path: daemon.log_path,
      cwd: daemon.cwd
    }
  end

  defp parse_status_details(output) do
    case output |> String.trim() |> String.split("\t", parts: 5) do
      [created, attached, pane_pid, command, current_path] ->
        %{
          created_at_epoch: parse_integer(created),
          attached: parse_integer(attached),
          pane_pid: parse_integer(pane_pid),
          command: command,
          current_path: current_path
        }

      _other ->
        %{}
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value || "") do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp daemon_env(%{db_path: db_path}) do
    []
    |> put_env("JX_DB", db_path)
    |> put_env("JX_USE_ESCRIPT", escript_env())
    |> put_env("MIX_ENV", System.get_env("MIX_ENV"))
  end

  defp escript_env do
    System.get_env("JX_USE_ESCRIPT")
  end

  defp put_env(env, _key, nil), do: env
  defp put_env(env, _key, ""), do: env
  defp put_env(env, key, value), do: env ++ ["#{key}=#{value}"]

  defp put_option(args, _option, nil), do: args
  defp put_option(args, _option, ""), do: args
  defp put_option(args, option, value), do: args ++ [option, to_string(value)]

  defp put_flag(args, _flag, false), do: args
  defp put_flag(args, flag, true), do: args ++ [flag]

  defp put_ack_flag(args, true), do: args ++ ["--ack"]
  defp put_ack_flag(args, false), do: args ++ ["--no-ack"]

  defp default_cli_path(cwd) do
    bin_jx = Path.join(cwd, "bin/jx")
    escript_jx = Path.join(cwd, "jx")

    cond do
      File.exists?(bin_jx) -> bin_jx
      File.exists?(escript_jx) -> escript_jx
      executable = System.find_executable("jx") -> executable
      true -> "jx"
    end
  end

  defp tail_lines(contents, lines) do
    contents
    |> String.split("\n")
    |> Enum.take(-lines)
    |> Enum.join("\n")
  end

  defp tmux(daemon, args) do
    System.cmd("tmux", Tmux.args(args, daemon.tmux_server), stderr_to_stdout: true)
  end
end
