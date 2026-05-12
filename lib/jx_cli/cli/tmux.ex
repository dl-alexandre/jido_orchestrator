defmodule JX.CLI.Tmux do
  @moduledoc false

  alias JX.Tmux
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_table: 2, validate_options: 1]

  @ls_usage "jx tmux ls <host> [--all] [--server <server>]"
  @panes_usage "jx tmux panes <host> [--all] [--server <server>]"
  @capture_usage "jx tmux capture <host> <session> [--server <server>] [--window 0] [--pane 0] [-n 80]"
  @send_usage "jx tmux send <host> <session> \"<message>\" [--server <server>] [--window 0] [--pane 0] [--no-enter]"
  @attach_usage "jx tmux attach <host> <session> [--server <server>]"
  @stop_usage "jx tmux stop <host> <session> [--server <server>]"

  def usage_lines do
    [
      @ls_usage,
      @panes_usage,
      @capture_usage,
      @send_usage,
      @attach_usage,
      @stop_usage
    ]
  end

  def usage, do: Enum.join(usage_lines(), " | ")

  def run(["ls", host_name | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [all: :boolean, server: :string])
    server = parsed[:server] || Tmux.managed_server()

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @ls_usage),
         :ok <- validate_tmux_options(parsed),
         :ok <- validate_tmux_server(server),
         :ok <- start_app(opts),
         {:ok, sessions} <-
           apply(workspace(opts), :list_tmux_sessions, [
             host_name,
             [all_tmux: parsed[:all], tmux_server: server]
           ]) do
      print_tmux_sessions(sessions)
      :ok
    end
  end

  def run(["panes", host_name | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [all: :boolean, server: :string])
    server = parsed[:server] || Tmux.managed_server()

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @panes_usage),
         :ok <- validate_tmux_options(parsed),
         :ok <- validate_tmux_server(server),
         :ok <- start_app(opts),
         {:ok, panes} <-
           apply(workspace(opts), :list_tmux_panes, [
             host_name,
             [all_tmux: parsed[:all], tmux_server: server]
           ]) do
      print_tmux_panes(panes)
      :ok
    end
  end

  def run(["capture", host_name, session_name | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [server: :string, window: :integer, pane: :integer, n: :integer],
        aliases: [n: :n]
      )

    server = parsed[:server] || Tmux.managed_server()
    window = parsed[:window] || 0
    pane = parsed[:pane] || 0
    lines = parsed[:n] || 80

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @capture_usage),
         :ok <- validate_tmux_server(server),
         :ok <- validate_non_negative("window", window),
         :ok <- validate_non_negative("pane", pane),
         :ok <- validate_positive("n", lines),
         :ok <- start_app(opts),
         {:ok, output} <-
           apply(workspace(opts), :capture_tmux_pane, [
             host_name,
             session_name,
             [
               tmux_server: server,
               window: window,
               pane: pane,
               lines: lines
             ]
           ]) do
      IO.write(output)
      :ok
    end
  end

  def run(["send", host_name, session_name | args], opts) do
    {parsed, message_parts, invalid} =
      OptionParser.parse(args,
        strict: [server: :string, window: :integer, pane: :integer, no_enter: :boolean]
      )

    server = parsed[:server] || Tmux.managed_server()
    window = parsed[:window] || 0
    pane = parsed[:pane] || 0
    message = message_parts |> Enum.join(" ") |> String.trim()

    with :ok <- validate_options(invalid),
         :ok <- validate_tmux_server(server),
         :ok <- validate_non_negative("window", window),
         :ok <- validate_non_negative("pane", pane),
         {:ok, message} <- required_message(message, @send_usage),
         :ok <- start_app(opts),
         {:ok, directive} <-
           apply(workspace(opts), :send_tmux, [
             host_name,
             session_name,
             message,
             [
               tmux_server: server,
               window: window,
               pane: pane,
               enter: !parsed[:no_enter]
             ]
           ]) do
      IO.puts(
        "directive #{directive.directive_id} sent to #{host_name}/#{server}/#{session_name}:#{window}.#{pane}"
      )

      :ok
    end
  end

  def run(["attach", host_name, session_name | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [server: :string])
    server = parsed[:server] || Tmux.managed_server()

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @attach_usage),
         :ok <- validate_tmux_server(server),
         :ok <- start_app(opts) do
      apply(workspace(opts), :attach_tmux, [host_name, session_name, [tmux_server: server]])
    end
  end

  def run(["stop", host_name, session_name | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [server: :string])
    server = parsed[:server] || Tmux.managed_server()

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @stop_usage),
         :ok <- validate_tmux_server(server),
         :ok <- start_app(opts),
         :ok <-
           apply(workspace(opts), :stop_tmux, [host_name, session_name, [tmux_server: server]]) do
      IO.puts("tmux session #{session_name} stopped on #{host_name}/#{server}")
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

  defp validate_tmux_server(server) do
    if Tmux.valid_server?(server) do
      :ok
    else
      {:error,
       "invalid tmux server #{inspect(server)}; use default, #{Tmux.managed_server()}, socket:<name>, or a tmux -L name"}
    end
  end

  defp validate_tmux_options(opts) do
    if opts[:all] && opts[:server] do
      {:error, "use either --all or --server, not both"}
    else
      :ok
    end
  end

  defp validate_non_negative(_name, value) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative(name, _value), do: {:error, "#{name} must be a non-negative integer"}

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp required_message(message, _usage) when is_binary(message) and message != "" do
    {:ok, message}
  end

  defp required_message(_message, usage), do: {:error, "usage: #{usage}"}

  defp print_tmux_sessions([]), do: IO.puts("no sessions")

  defp print_tmux_sessions(sessions) do
    rows =
      Enum.map(sessions, fn session ->
        [
          session.server,
          session.name,
          format_time(session.created_at),
          Integer.to_string(session.attached),
          Integer.to_string(session.windows),
          session.current_path
        ]
      end)

    print_table(["SERVER", "SESSION", "CREATED", "ATTACHED", "WINDOWS", "PATH"], rows)
  end

  defp print_tmux_panes([]), do: IO.puts("no panes")

  defp print_tmux_panes(panes) do
    rows =
      Enum.map(panes, fn pane ->
        [
          pane.server,
          pane.session,
          Integer.to_string(pane.window),
          Integer.to_string(pane.pane),
          pane.tty,
          if(pane.active, do: "yes", else: "no"),
          pane.kind,
          pane.command,
          pane.current_path,
          pane.title
        ]
      end)

    print_table(
      ["SERVER", "SESSION", "WIN", "PANE", "TTY", "ACTIVE", "KIND", "COMMAND", "PATH", "TITLE"],
      rows
    )
  end

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value) when is_binary(value), do: if(value == "", do: "-", else: value)
end
