defmodule JX.CliRuntime do
  @moduledoc """
  Prepares runtime files before the CLI starts the OTP application.

  Mix escripts are a single file, but some dependencies need real files on disk:
  tzdata reads release ETS files and exqlite loads a native SQLite NIF. The CLI
  extracts those files into a stable local cache before starting dependencies so
  the standalone binary can run without Mix.
  """

  @runtime_dir Path.expand("~/.jx/runtime")
  @tzdata_dir Path.expand("~/.jx/tzdata")
  @tzdata_release_dir "release_ets"
  @jx_app "jx"
  @exqlite_app "exqlite"

  @doc """
  Ensures dependency runtime files are available from real directories.
  """
  def prepare(opts \\ []) do
    case escript_archive_files() do
      {:error, _reason} = error ->
        error

      archive_files ->
        with :ok <- prepare_jx(archive_files, opts),
             :ok <- prepare_exqlite(archive_files, opts),
             :ok <- prepare_tzdata(archive_files, opts) do
          :ok
        end
    end
  end

  defp prepare_jx(:not_found, _opts), do: :ok

  defp prepare_jx({:ok, archive_files}, opts) do
    app_dir =
      Keyword.get(opts, :jx_dir) || Path.join(@runtime_dir, @jx_app)

    with :ok <- extract_archive_app(archive_files, @jx_app, app_dir) do
      add_ebin_path(app_dir)
      load_app(:jx)
      :ok
    end
  end

  defp prepare_exqlite(:not_found, _opts), do: :ok

  defp prepare_exqlite({:ok, archive_files}, opts) do
    app_dir = Keyword.get(opts, :exqlite_dir) || Path.join(@runtime_dir, @exqlite_app)

    with :ok <- extract_archive_app(archive_files, @exqlite_app, app_dir),
         :ok <- ensure_exqlite_nif(app_dir) do
      add_ebin_path(app_dir)
      load_app(:exqlite)
      :ok
    end
  end

  defp add_ebin_path(app_dir) do
    app_dir
    |> Path.join("ebin")
    |> String.to_charlist()
    |> :code.add_patha()
  end

  defp ensure_exqlite_nif(app_dir) do
    app_dir
    |> Path.join("priv/sqlite3_nif.*")
    |> Path.wildcard()
    |> case do
      [] ->
        {:error,
         "exqlite NIF was not found in the escript; rebuild with include_priv_for: [:exqlite]"}

      _files ->
        :ok
    end
  end

  defp prepare_tzdata(archive_files, opts) do
    data_dir = Keyword.get(opts, :tzdata_dir) || tzdata_dir_from_env() || @tzdata_dir
    release_dir = Path.join(data_dir, @tzdata_release_dir)

    load_app(:tzdata)
    Application.put_env(:tzdata, :data_dir, data_dir)
    Application.put_env(:tzdata, :autoupdate, Keyword.get(opts, :tzdata_autoupdate, :disabled))

    ensure_tzdata_release_files(archive_files, release_dir)
  end

  defp ensure_tzdata_release_files(archive_files, release_dir) do
    with :ok <- File.mkdir_p(release_dir) do
      if tzdata_release_files?(release_dir) do
        :ok
      else
        copy_tzdata_release_files(archive_files, release_dir)
      end
    end
  end

  defp tzdata_release_files?(release_dir) do
    release_dir
    |> Path.join("*.ets")
    |> Path.wildcard()
    |> Enum.any?()
  end

  defp copy_tzdata_release_files(archive_files, release_dir) do
    case copy_tzdata_release_files_from_escript(archive_files, release_dir) do
      :ok -> :ok
      :not_found -> copy_tzdata_release_files_from_priv(release_dir)
      {:error, _reason} = error -> error
    end
  end

  defp copy_tzdata_release_files_from_escript(:not_found, _release_dir), do: :not_found

  defp copy_tzdata_release_files_from_escript({:ok, archive_files}, release_dir) do
    release_files =
      Enum.filter(archive_files, &tzdata_archive_release_file?/1)

    if release_files == [] do
      :not_found
    else
      write_archive_entries(release_files, "tzdata/priv/#{@tzdata_release_dir}", release_dir)
    end
  end

  defp tzdata_archive_release_file?({path, contents})
       when is_list(path) and is_binary(contents) do
    path = to_string(path)

    String.starts_with?(path, "tzdata/priv/#{@tzdata_release_dir}/") and
      String.ends_with?(path, ".ets")
  end

  defp tzdata_archive_release_file?(_entry), do: false

  defp copy_tzdata_release_files_from_priv(release_dir) do
    with {:ok, source_dir} <- tzdata_release_dir(),
         {:ok, source_files} <- File.ls(source_dir),
         release_files <- Enum.filter(source_files, &release_file?/1),
         false <- release_files == [] do
      copy_priv_release_files(source_dir, release_dir, release_files)
    else
      _missing -> {:error, missing_tzdata_error(release_dir)}
    end
  end

  defp tzdata_release_dir do
    case :code.priv_dir(:tzdata) do
      priv_dir when is_list(priv_dir) ->
        {:ok, Path.join(to_string(priv_dir), @tzdata_release_dir)}

      _missing ->
        :error
    end
  end

  defp release_file?(file), do: String.ends_with?(file, ".ets")

  defp copy_priv_release_files(source_dir, release_dir, release_files) do
    Enum.reduce_while(release_files, :ok, fn file, :ok ->
      source = Path.join(source_dir, file)
      target = Path.join(release_dir, file)

      case File.cp(source, target) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, failed_error(reason)}}
      end
    end)
  end

  defp extract_archive_app(archive_files, app_name, target_dir) do
    entries =
      Enum.filter(archive_files, fn
        {path, contents} when is_list(path) and is_binary(contents) ->
          String.starts_with?(to_string(path), "#{app_name}/")

        _entry ->
          false
      end)

    if entries == [] do
      {:error, "app #{app_name} was not found in the escript archive"}
    else
      write_archive_entries(entries, app_name, target_dir)
    end
  end

  defp write_archive_entries(entries, source_prefix, target_dir) do
    Enum.reduce_while(entries, :ok, fn {path, contents}, :ok ->
      relative_path =
        path
        |> to_string()
        |> String.replace_prefix(source_prefix <> "/", "")

      target = Path.join(target_dir, relative_path)

      case write_file(target, contents) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, failed_error(reason)}}
      end
    end)
  end

  defp write_file(path, contents) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, contents)
    end
  end

  defp escript_archive_files do
    with {:ok, archive} <- escript_archive() do
      case :zip.extract(archive, [:memory]) do
        {:ok, files} -> {:ok, files}
        {:error, reason} -> {:error, "failed to read escript archive: #{inspect(reason)}"}
      end
    end
  end

  defp escript_archive do
    case escript_extract() do
      {:ok, entries} ->
        entries
        |> List.keyfind(:archive, 0)
        |> case do
          {:archive, archive} when is_binary(archive) -> {:ok, archive}
          _missing -> :not_found
        end

      _not_found ->
        :not_found
    end
  end

  defp escript_extract do
    script_name = :escript.script_name()

    if mix_runtime?(script_name) do
      :not_found
    else
      try do
        :escript.extract(script_name, [])
      rescue
        _error -> :not_found
      catch
        _kind, _reason -> :not_found
      end
    end
  end

  defp mix_runtime?(script_name) do
    script_name
    |> to_string()
    |> Path.basename()
    |> Kernel.in(["mix", "iex"])
  end

  defp load_app(app) do
    case Application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp tzdata_dir_from_env do
    System.get_env("JX_TZDATA_DIR")
  end

  defp missing_tzdata_error(release_dir) do
    "tzdata release files were not found; rebuild the escript or set JX_TZDATA_DIR to a directory containing #{release_dir}/*.ets"
  end

  defp failed_error(reason), do: "failed to prepare CLI runtime files: #{inspect(reason)}"
end
