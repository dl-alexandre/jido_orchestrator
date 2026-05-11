Application.stop(:jx)
Application.put_env(:jx, :ssh_adapter, JX.SSH.Fake)

test_db =
  :jx
  |> Application.fetch_env!(JX.Repo)
  |> Keyword.fetch!(:database)

File.mkdir_p!(Path.dirname(test_db))

for suffix <- ["", "-shm", "-wal", "-journal"] do
  File.rm_rf!(test_db <> suffix)
end

System.at_exit(fn _status ->
  for suffix <- ["", "-shm", "-wal", "-journal"] do
    File.rm_rf!(test_db <> suffix)
  end
end)

{:ok, _apps} = Application.ensure_all_started(:jx)
Ecto.Migrator.run(JX.Repo, :up, all: true)

ExUnit.start()
