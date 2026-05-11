defmodule JX.Notifications.FileSink do
  @moduledoc """
  JSONL notification sink.

  Relative paths are written under the JX state directory. Absolute paths must
  also resolve inside that state directory. This keeps sink output scoped to
  `~/.jx` by default, or to `JX_STATE_DIR` / the configured database directory.
  """

  @behaviour JX.Notifications.Sink

  alias JX.Repo

  @default_filename "notifications.jsonl"

  @impl true
  def deliver(event, opts \\ []) when is_map(event) do
    with {:ok, path} <- resolve_path(opts),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      line = Jason.encode!(event) <> "\n"
      File.write(path, line, [:append, :utf8])
    end
  end

  def resolve_path(opts \\ []) do
    state_dir = state_dir(opts)

    path =
      opts
      |> Keyword.get(:path, @default_filename)
      |> to_string()
      |> path_under(state_dir)

    if inside?(path, state_dir) do
      {:ok, path}
    else
      {:error, {:unsafe_notification_path, path, state_dir}}
    end
  end

  defp path_under(path, state_dir) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, state_dir)
    end
  end

  defp inside?(path, state_dir) do
    path = Path.expand(path)
    state_dir = Path.expand(state_dir)
    path == state_dir or String.starts_with?(path, state_dir <> "/")
  end

  defp state_dir(opts) do
    opts
    |> Keyword.get(:state_dir)
    |> case do
      nil -> configured_state_dir()
      dir -> Path.expand(to_string(dir))
    end
  end

  defp configured_state_dir do
    cond do
      present?(System.get_env("JX_STATE_DIR")) ->
        Path.expand(System.fetch_env!("JX_STATE_DIR"))

      present?(repo_database()) ->
        repo_database()
        |> Path.expand()
        |> Path.dirname()

      true ->
        Path.expand("~/.jx")
    end
  end

  defp repo_database do
    :jx
    |> Application.get_env(Repo, [])
    |> Keyword.get(:database)
    |> case do
      ":memory:" -> nil
      database -> database
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
