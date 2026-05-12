defmodule JX.CLI.AgentsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Agents

  defmodule FakeWorkspace do
    def register_agent(attrs) do
      send(self(), {:register_agent, attrs})

      {:ok,
       agent(%{
         agent_id: attrs.agent_id,
         name: attrs.name,
         capabilities: attrs.capabilities,
         workspace_affinity: attrs.workspace_affinity,
         heartbeat_ttl_seconds: attrs.heartbeat_ttl_seconds
       })}
    end

    def heartbeat_agent(agent_id) do
      send(self(), {:heartbeat_agent, agent_id})
      {:ok, agent(%{agent_id: agent_id})}
    end

    def list_agents(opts) do
      send(self(), {:list_agents, opts})
      [agent(%{})]
    end

    defp agent(attrs) do
      %{
        agent_id: Map.get(attrs, :agent_id, "agent-1"),
        name: Map.get(attrs, :name, "Agent 1"),
        status: "idle",
        capabilities: Map.get(attrs, :capabilities, ["elixir"]),
        workspace_affinity: Map.get(attrs, :workspace_affinity, ["workspace-1"]),
        heartbeat_ttl_seconds: Map.get(attrs, :heartbeat_ttl_seconds, 120),
        last_heartbeat_at: nil,
        active_assignments: 0,
        stale: false
      }
    end
  end

  test "agents register owns parsing and json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Agents.run(
                   [
                     "register",
                     "agent-1",
                     "--name",
                     "Agent One",
                     "--capability",
                     "elixir",
                     "--capability",
                     "ssh",
                     "--workspace",
                     "workspace-1",
                     "--ttl-seconds",
                     "300",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:register_agent, attrs}
    assert attrs.agent_id == "agent-1"
    assert attrs.name == "Agent One"
    assert attrs.capabilities == ["elixir", "ssh"]
    assert attrs.workspace_affinity == ["workspace-1"]
    assert attrs.heartbeat_ttl_seconds == 300

    assert %{
             "agent_id" => "agent-1",
             "capabilities" => ["elixir", "ssh"],
             "workspace_affinity" => ["workspace-1"]
           } = Jason.decode!(output)
  end

  test "agents register validates ttl before starting the app" do
    assert {:error, message} =
             Agents.run(["register", "agent-1", "--ttl-seconds", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "ttl-seconds must be a positive integer"
    refute_received :started
    refute_received :register_agent
  end

  test "agents heartbeat renders stable text" do
    output =
      capture_io(fn ->
        assert :ok =
                 Agents.run(["heartbeat", "agent-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:heartbeat_agent, "agent-1"}
    assert output =~ "heartbeat agent-1"
    assert output =~ "status: idle"
    assert output =~ "workspace_affinity: workspace-1"
  end

  test "agents ls owns status filter and json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Agents.run(["ls", "--status", "all", "-n", "10", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:list_agents, opts}
    assert opts[:status] == "all"
    assert opts[:limit] == 10

    assert %{"agents" => [%{"agent_id" => "agent-1"}]} = Jason.decode!(output)
  end

  test "agents ls validates status before starting the app" do
    assert {:error, message} =
             Agents.run(["ls", "--status", "bad"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported agent status"
    refute_received :started
    refute_received :list_agents
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
