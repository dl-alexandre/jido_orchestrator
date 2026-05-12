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
  end

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

  test "host doctor validates before starting the app" do
    assert {:error, message} =
             Host.run(["doctor", "local", "--agent", "bad-agent"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported agent"
    refute_received :started
  end

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

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
