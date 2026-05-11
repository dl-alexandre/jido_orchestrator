defmodule JX.SSH.Local do
  @moduledoc """
  Local execution adapter that satisfies the SSH behaviour without using SSH.
  """

  @behaviour JX.SSH

  alias JX.Hosts.Host
  alias JX.Shell
  alias JX.Tmux

  @impl true
  def run(%Host{}, script, _opts \\ []) do
    output_path = Path.join(System.tmp_dir!(), "jx-local-#{unique_id()}.log")

    wrapped_script = """
    (
    #{script}
    ) > #{Shell.quote(output_path)} 2>&1
    """

    try do
      case System.cmd("sh", ["-lc", wrapped_script]) do
        {_output, 0} -> {:ok, read_output(output_path)}
        {_output, status} -> {:error, {:local_failed, status, read_output(output_path)}}
      end
    after
      File.rm(output_path)
    end
  end

  @impl true
  def attach(%Host{}, session_name, opts \\ []) do
    server = Keyword.get(opts, :tmux_server, Tmux.managed_server())

    case System.cmd(
           "tmux",
           Tmux.args(["attach-session", "-t", Tmux.target(session_name)], server),
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, {:attach_failed, status}}
    end
  end

  @impl true
  def stream_log(%Host{}, log_path, opts \\ []) do
    lines = Keyword.get(opts, :lines, 200)
    follow? = Keyword.get(opts, :follow, false)
    flag = if follow?, do: "-f -n", else: "-n"

    script =
      "test -f #{Shell.quote(log_path)} && tail #{flag} #{lines} #{Shell.quote(log_path)} || true"

    case System.cmd("sh", ["-lc", script], into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, {:logs_failed, status}}
    end
  end

  defp read_output(path) do
    case File.read(path) do
      {:ok, output} -> output
      {:error, _reason} -> ""
    end
  end

  defp unique_id do
    6
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
