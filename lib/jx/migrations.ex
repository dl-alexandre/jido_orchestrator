defmodule JX.Migrations do
  @moduledoc """
  Runtime migration helper for the CLI.
  """

  alias JX.Repo

  def migrate(opts \\ []) do
    Application.ensure_all_started(:jx)
    migrate_started(opts)
  end

  def migrate_started(opts \\ []) do
    log? = Keyword.get(opts, :log, true)

    with_migration_lock(fn ->
      Ecto.Migrator.run(Repo, :up, all: true, log: log?)
    end)

    :ok
  end

  defp with_migration_lock(fun) do
    case migration_lock_path() do
      nil ->
        fun.()

      lock_path ->
        lock_path
        |> Path.dirname()
        |> File.mkdir_p!()

        acquire_migration_lock(lock_path)

        try do
          fun.()
        after
          File.rm(lock_path)
        end
    end
  end

  defp acquire_migration_lock(lock_path) do
    deadline = System.monotonic_time(:millisecond) + 30_000
    acquire_migration_lock(lock_path, deadline)
  end

  defp acquire_migration_lock(lock_path, deadline) do
    case File.open(lock_path, [:write, :exclusive], fn file ->
           IO.write(file, "#{inspect(self())}\n")
         end) do
      {:ok, :ok} ->
        :ok

      {:error, :eexist} ->
        maybe_remove_stale_lock(lock_path)

        if System.monotonic_time(:millisecond) >= deadline do
          raise "timed out waiting for migration lock #{lock_path}"
        end

        Process.sleep(50)
        acquire_migration_lock(lock_path, deadline)

      {:error, reason} ->
        raise "could not acquire migration lock #{lock_path}: #{inspect(reason)}"
    end
  end

  defp maybe_remove_stale_lock(lock_path) do
    case File.stat(lock_path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        if System.os_time(:second) - mtime > 120 do
          File.rm(lock_path)
        else
          :ok
        end

      _other ->
        :ok
    end
  end

  defp migration_lock_path do
    :jx
    |> Application.get_env(Repo, [])
    |> Keyword.get(:database)
    |> case do
      nil -> nil
      ":memory:" -> nil
      database -> Path.expand("#{database}.migrate.lock")
    end
  end
end
