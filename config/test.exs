import Config

config :jx, JX.Repo,
  database:
    System.get_env("JX_TEST_DB") ||
      Path.join(
        System.tmp_dir!(),
        "jx-test-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}.db"
      ),
  pool_size: 1

config :logger, level: :warning
