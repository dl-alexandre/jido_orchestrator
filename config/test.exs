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

# Disable background capacity polling in tests to avoid SSH calls and noise.
config :jx, JX.HostCapacity.CapacityPoller, poll_interval_ms: 0
