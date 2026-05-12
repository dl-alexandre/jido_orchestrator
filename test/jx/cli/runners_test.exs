defmodule JX.CLI.RunnersTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Runners

  defmodule FakeWorkspace do
    def register_runner(attrs) do
      send(self(), {:register_runner, attrs})

      {:ok,
       runner(%{
         runner_id: attrs.runner_id,
         agent_id: attrs.agent_id,
         host_name: attrs.host_name,
         capabilities: attrs.capabilities,
         workspace_affinity: attrs.workspace_affinity,
         heartbeat_ttl_seconds: attrs.heartbeat_ttl_seconds,
         tmux_server: attrs.tmux_server,
         tmux_session_prefix: attrs.tmux_session_prefix
       })}
    end

    def heartbeat_runner(runner_id, opts) do
      send(self(), {:heartbeat_runner, runner_id, opts})
      {:ok, runner(%{runner_id: runner_id})}
    end

    def list_runners(opts) do
      send(self(), {:list_runners, opts})
      [runner(%{})]
    end

    def get_runner(runner_id) do
      send(self(), {:get_runner, runner_id})
      runner(%{runner_id: runner_id})
    end

    defp runner(attrs) do
      %{
        runner_id: Map.get(attrs, :runner_id, "runner-1"),
        agent_id: Map.get(attrs, :agent_id, "agent-1"),
        host_name: Map.get(attrs, :host_name, "local"),
        status: "idle",
        capabilities: Map.get(attrs, :capabilities, ["elixir"]),
        workspace_affinity: Map.get(attrs, :workspace_affinity, ["workspace-1"]),
        heartbeat_ttl_seconds: Map.get(attrs, :heartbeat_ttl_seconds, 120),
        last_heartbeat_at: nil,
        tmux_server: Map.get(attrs, :tmux_server, "jx"),
        tmux_session_prefix: Map.get(attrs, :tmux_session_prefix, "jx-runner-1"),
        active_sessions: 0,
        stale: false
      }
    end
  end

  test "runners register owns parsing and json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Runners.run(
                   [
                     "register",
                     "runner-1",
                     "--agent",
                     "agent-1",
                     "--host",
                     "local",
                     "--capability",
                     "elixir",
                     "--capability",
                     "ssh",
                     "--workspace",
                     "workspace-1",
                     "--ttl-seconds",
                     "300",
                     "--tmux-server",
                     "jx-dev",
                     "--tmux-session-prefix",
                     "jx-dev-runner",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:register_runner, attrs}
    assert attrs.runner_id == "runner-1"
    assert attrs.agent_id == "agent-1"
    assert attrs.host_name == "local"
    assert attrs.capabilities == ["elixir", "ssh"]
    assert attrs.workspace_affinity == ["workspace-1"]
    assert attrs.heartbeat_ttl_seconds == 300
    assert attrs.tmux_server == "jx-dev"
    assert attrs.tmux_session_prefix == "jx-dev-runner"

    assert %{
             "runner_id" => "runner-1",
             "agent_id" => "agent-1",
             "capabilities" => ["elixir", "ssh"],
             "workspace_affinity" => ["workspace-1"]
           } = Jason.decode!(output)
  end

  test "runners register validates ttl before starting the app" do
    assert {:error, message} =
             Runners.run(["register", "runner-1", "--ttl-seconds", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "ttl-seconds must be a positive integer"
    refute_received :started
    refute_received :register_runner
  end

  test "runners heartbeat passes session and renders stable text" do
    output =
      capture_io(fn ->
        assert :ok =
                 Runners.run(["heartbeat", "runner-1", "--session", "rsess-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:heartbeat_runner, "runner-1", [session_id: "rsess-1"]}
    assert output =~ "heartbeat runner-1"
    assert output =~ "agent: agent-1"
    assert output =~ "tmux_server: jx"
  end

  test "runners ls owns status filter and json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Runners.run(["ls", "--status", "all", "-n", "10", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:list_runners, opts}
    assert opts[:status] == "all"
    assert opts[:limit] == 10

    assert %{"runners" => [%{"runner_id" => "runner-1"}]} = Jason.decode!(output)
  end

  test "runners ls validates status before starting the app" do
    assert {:error, message} =
             Runners.run(["ls", "--status", "bad"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported runner status"
    refute_received :started
    refute_received :list_runners
  end

  test "runners show returns runner details through workspace boundary" do
    output =
      capture_io(fn ->
        assert :ok =
                 Runners.run(["show", "runner-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:get_runner, "runner-1"}
    assert %{"runner_id" => "runner-1", "tmux_server" => "jx"} = Jason.decode!(output)
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
