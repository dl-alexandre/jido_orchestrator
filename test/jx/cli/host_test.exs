defmodule JX.CLI.HostTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Host

  defmodule FakeWorkspace do
    def add_host(attrs) do
      send(self(), {:add_host, attrs})
      {:ok, Map.merge(%{ssh_target: nil}, attrs)}
    end

    def list_hosts do
      [
        %{name: "local", transport: "local", ssh_target: nil, workspace_path: "/tmp/jx"},
        %{
          name: "build",
          transport: "ssh",
          ssh_target: "dev@example.test",
          workspace_path: "/srv/agent"
        }
      ]
    end

    def doctor_host("fail" = name, opts) do
      send(self(), {:doctor_host, name, opts})

      {:ok,
       %{
         host: %{name: name, transport: "local", ssh_target: nil, workspace_path: "/tmp/jx"},
         groups: [
           %{
             name: "execution",
             checks: [
               %{status: :ok, name: "can execute command", detail: "ok"},
               %{status: :fail, name: "disk space", detail: "full"}
             ]
           }
         ]
       }}
    end

    def doctor_host(name, opts) do
      send(self(), {:doctor_host, name, opts})
      {:ok, doctor_report(name)}
    end

    def doctor_hosts(opts) do
      send(self(), {:doctor_hosts, opts})
      {:ok, %{generated_at: "2026-05-12T00:00:00Z", reports: [doctor_report("local")]}}
    end

    defp doctor_report(name) do
      %{
        host: %{name: name, transport: "local", ssh_target: nil, workspace_path: "/tmp/jx"},
        groups: [
          %{
            name: "execution",
            checks: [%{status: :ok, name: "can execute command", detail: "ok"}]
          }
        ]
      }
    end

    def capacity_host(name, opts) do
      send(self(), {:capacity_host, name, opts})

      {:ok,
       %{
         host: name,
         resources: %{
           ram_total_mb: 16384,
           ram_available_mb: 8192,
           disk_total_mb: 500_000,
           disk_available_mb: 250_000,
           cpu_cores: 8
         },
         profile: opts[:profile] || JX.HostCapacity.default_profile(),
         limits: %{by_ram: 2, by_disk: 122, by_cpu: 20},
         recommended_worktrees: 2
       }}
    end

    def capacity_hosts(opts) do
      send(self(), {:capacity_hosts, opts})

      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         results: [
           %{
             host: "local",
             resources: %{
               ram_total_mb: 16384,
               ram_available_mb: 8192,
               disk_total_mb: 500_000,
               disk_available_mb: 250_000,
               cpu_cores: 8
             },
             profile: opts[:profile] || JX.HostCapacity.default_profile(),
             limits: %{by_ram: 2, by_disk: 122, by_cpu: 20},
             recommended_worktrees: 2
           }
         ]
       }}
    end

    def set_capacity_limit(name, limit) do
      send(self(), {:set_capacity_limit, name, limit})
      {:ok, %{name: name, capacity_limit: limit}}
    end

    def evaluate_capacity("build" = name) do
      send(self(), {:evaluate_capacity, name, []})

      {:ok,
       %{
         host: name,
         observations_analysed: 5,
         avg_headroom_per_slot: 4096,
         avg_load_ratio: 0.45,
         current_limit: 4,
         verdict: :hold,
         suggested_limit: nil,
         reasoning:
           "RAM pressure ratio 1.33 (133% of profile) is within the healthy 0.5–2.0 range; avg CPU load 45%. Current limit looks right."
       }}
    end

    def evaluate_capacity(name) do
      send(self(), {:evaluate_capacity, name, []})

      {:ok,
       %{
         host: name,
         observations_analysed: 0,
         avg_headroom_per_slot: nil,
         avg_load_ratio: nil,
         current_limit: nil,
         verdict: :insufficient_data,
         suggested_limit: nil,
         reasoning:
           "Need at least 3 observations under load; only 0 recorded so far. Run more sessions and observe again."
       }}
    end

    def evaluate_all_capacity do
      send(self(), :evaluate_all_capacity)

      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         results: [
           %{
             host: "local",
             observations_analysed: 5,
             avg_headroom_per_slot: 4096,
             avg_load_ratio: 0.45,
             current_limit: 4,
             verdict: :hold,
             suggested_limit: nil,
             reasoning:
               "RAM pressure ratio 1.33 (133% of profile) is within the healthy 0.5–2.0 range; avg CPU load 45%. Current limit looks right."
           }
         ]
       }}
    end

    def evaluate_all_capacity(_opts), do: evaluate_all_capacity()
  end

  defmodule FakeEmptyWorkspace do
    def list_hosts, do: []

    def doctor_hosts(opts) do
      send(self(), {:doctor_hosts_empty, opts})
      {:ok, %{generated_at: "2026-05-12T00:00:00Z", reports: []}}
    end

    def capacity_hosts(opts) do
      send(self(), {:capacity_hosts_empty, opts})
      {:ok, %{generated_at: "2026-05-12T00:00:00Z", results: []}}
    end

    def evaluate_all_capacity do
      send(self(), :evaluate_all_capacity_empty)
      {:ok, %{generated_at: "2026-05-12T00:00:00Z", results: []}}
    end

    def evaluate_all_capacity(_opts), do: evaluate_all_capacity()
  end

  # ---------------------------------------------------------------------------
  # host add
  # ---------------------------------------------------------------------------

  test "host add owns local argument parsing and output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run(["add", "local", "--local", "--workspace", "/tmp/jx"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output == "host local registered: local workspace=/tmp/jx\n"
    assert_received :started
    assert_received {:add_host, %{name: "local", transport: "local", workspace_path: "/tmp/jx"}}
  end

  test "host add owns ssh argument parsing and output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run(
                   ["add", "build", "--ssh", "dev@example.test", "--workspace", "/srv/agent"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output == "host build registered: dev@example.test workspace=/srv/agent\n"
    assert_received :started

    assert_received {:add_host,
                     %{name: "build", transport: "ssh", ssh_target: "dev@example.test", workspace_path: "/srv/agent"}}
  end

  # ---------------------------------------------------------------------------
  # host doctor
  # ---------------------------------------------------------------------------

  test "host doctor validates before starting the app" do
    assert {:error, message} =
             Host.run(["doctor", "local", "--agent", "bad-agent"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported agent"
    refute_received :started
  end

  test "host doctor renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run(["doctor", "local"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "host local (local)"
    assert output =~ "execution"
    assert output =~ "OK can execute command - ok"
    assert_received :started
    assert_received {:doctor_host, "local", _opts}
  end

  test "host doctor returns error when checks fail" do
    output =
      capture_io(fn ->
        assert {:error, "doctor checks failed"} =
                 Host.run(["doctor", "fail"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "FAIL disk space - full"
    assert_received :started
    assert_received {:doctor_host, "fail", _opts}
  end

  # ---------------------------------------------------------------------------
  # hosts doctor
  # ---------------------------------------------------------------------------

  test "hosts doctor owns json output and doctor options" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run_plural(
                   ["doctor", "--agent", "codex", "--transport", "native", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:doctor_hosts, opts}
    assert opts[:agents] == ["codex"]
    assert opts[:agent_transport] == "native"

    decoded = Jason.decode!(output)
    assert [%{"host" => "local", "passed" => true}] = decoded["hosts_doctor"]["reports"]
  end

  test "hosts doctor renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run_plural(
                   ["doctor", "--agent", "codex", "--transport", "native"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "host local (local)"
    assert output =~ "execution"
    assert output =~ "OK can execute command - ok"
    assert_received :started
    assert_received {:doctor_hosts, _opts}
  end

  test "hosts doctor renders no hosts text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run_plural(
                   ["doctor", "--agent", "codex", "--transport", "native"],
                   start_app: start_app_callback(),
                   workspace: FakeEmptyWorkspace
                 )
      end)

    assert_received :started
    assert_received {:doctor_hosts_empty, _opts}
    assert output == ""
  end

  # ---------------------------------------------------------------------------
  # host ls
  # ---------------------------------------------------------------------------

  test "host ls renders registered hosts" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run(["ls"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "HOST"
    assert output =~ "local"
    assert output =~ "build"
    assert output =~ "dev@example.test"
  end

  test "host ls renders no hosts when empty" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run(["ls"],
                   start_app: start_app_callback(),
                   workspace: FakeEmptyWorkspace
                 )
      end)

    assert output == "no hosts\n"
  end

  # ---------------------------------------------------------------------------
  # host capacity
  # ---------------------------------------------------------------------------

  test "host capacity renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run(["capacity", "local"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "host local"
    assert output =~ "resources"
    assert output =~ "RAM   8192 MB available / 16384 MB total"
    assert output =~ "disk  250000 MB available / 500000 MB total"
    assert output =~ "CPU   8 logical cores"
    assert output =~ "capacity"
    assert output =~ "by RAM   2 worktree(s)"
    assert output =~ "recommended: 2 concurrent worktree(s)"
    assert_received :started
    assert_received {:capacity_host, "local", _opts}
  end

  test "host capacity set renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run(["capacity", "set", "local", "4"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output == "host local capacity limit set to 4\n"
    assert_received :started
    assert_received {:set_capacity_limit, "local", 4}
  end

  test "host capacity set validates limit before starting the app" do
    assert {:error, "limit must be a positive integer"} =
             Host.run(["capacity", "set", "local", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    refute_received :started
    refute_received {:set_capacity_limit, _, _}
  end

  test "host capacity set validates non-integer limit before starting the app" do
    assert {:error, "limit must be a positive integer"} =
             Host.run(["capacity", "set", "local", "abc"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    refute_received :started
  end

  test "host capacity eval renders insufficient data text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run(["capacity", "eval", "local"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "host local"
    assert output =~ "verdict: insufficient data"
    assert output =~ "Need at least 3 observations under load"
    assert_received :started
    assert_received {:evaluate_capacity, "local", _opts}
  end

  test "host capacity eval renders normal text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run(["capacity", "eval", "build"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "host build"
    assert output =~ "observations analysed: 5"
    assert output =~ "avg RAM headroom/slot: 4096 MB"
    assert output =~ "current limit: 4"
    assert output =~ "verdict:       hold"
    assert output =~ "suggested limit: no change"
    assert output =~ "RAM pressure ratio 1.33"
    assert_received :started
    assert_received {:evaluate_capacity, "build", _opts}
  end

  # ---------------------------------------------------------------------------
  # hosts capacity
  # ---------------------------------------------------------------------------

  test "hosts capacity renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run_plural(
                   ["capacity", "--ram", "4096", "--disk", "1024", "--cpu", "0.5", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:capacity_hosts, opts}
    assert opts[:profile][:ram_mb_per_slot] == 4096
    assert opts[:profile][:disk_mb_per_slot] == 1024
    assert opts[:profile][:cpu_cores_per_slot] == 0.5

    decoded = Jason.decode!(output)
    assert [%{"host" => "local"}] = decoded["hosts_capacity"]
  end

  test "hosts capacity renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run_plural(
                   ["capacity", "--ram", "4096"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "host local"
    assert output =~ "RAM   8192 MB available / 16384 MB total"
    assert_received :started
    assert_received {:capacity_hosts, _opts}
  end

  test "hosts capacity renders no hosts text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run_plural(
                   ["capacity"],
                   start_app: start_app_callback(),
                   workspace: FakeEmptyWorkspace
                 )
      end)

    assert_received :started
    assert_received {:capacity_hosts_empty, _opts}
    assert output == ""
  end

  # ---------------------------------------------------------------------------
  # hosts capacity eval
  # ---------------------------------------------------------------------------

  test "hosts capacity eval renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run_plural(
                   ["capacity", "eval", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received :evaluate_all_capacity

    decoded = Jason.decode!(output)
    assert [%{"host" => "local", "verdict" => "hold"}] = decoded["hosts_capacity_eval"]
  end

  test "hosts capacity eval renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run_plural(
                   ["capacity", "eval"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "host local"
    assert output =~ "observations analysed: 5"
    assert output =~ "verdict:       hold"
    assert_received :started
    assert_received :evaluate_all_capacity
  end

  test "hosts capacity eval renders no hosts text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Host.run_plural(
                   ["capacity", "eval"],
                   start_app: start_app_callback(),
                   workspace: FakeEmptyWorkspace
                 )
      end)

    assert_received :started
    assert_received :evaluate_all_capacity_empty
    assert output == ""
  end

  # ---------------------------------------------------------------------------
  # Usage / error paths
  # ---------------------------------------------------------------------------

  test "host doctor without host returns usage error" do
    assert {:error, message} =
             Host.run(["doctor"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage: jx host doctor"
    refute_received :started
  end

  test "host unknown command returns usage error" do
    assert {:error, message} =
             Host.run(["unknown"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage: jx host add"
    refute_received :started
  end

  test "hosts unknown command returns usage error" do
    assert {:error, message} =
             Host.run_plural(["unknown"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage: jx hosts doctor"
    refute_received :started
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
