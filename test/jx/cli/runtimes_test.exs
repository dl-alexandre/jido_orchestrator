defmodule JX.CLI.RuntimesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Runtimes

  defmodule FakeWorkspace do
    def provision_runtime_for_action(action_id, opts) do
      send(self(), {:provision_runtime_for_action, action_id, opts})

      {:ok,
       runtime(%{
         action_id: action_id,
         workspace_id: "workspace-#{opts[:project]}",
         host_name: opts[:host] || "local",
         runner_id: opts[:runner_id],
         tools: opts[:tools],
         capabilities: opts[:capabilities],
         os: opts[:os],
         branch_isolation: opts[:branch_isolation],
         concurrency_limit: opts[:concurrency_limit]
       })}
    end

    def assign_runtime_action(runtime_id, action_id, opts) do
      send(self(), {:assign_runtime_action, runtime_id, action_id, opts})

      {:ok,
       %{
         runtime:
           runtime(%{
             runtime_id: runtime_id,
             action_id: action_id,
             status: "assigned",
             runner_id: opts[:runner_id],
             session_id: opts[:session_id],
             assignment_id: "asgn-1"
           }),
         assignment:
           assignment(%{
             action_id: action_id,
             runner_id: opts[:runner_id],
             session_id: opts[:session_id]
           })
       }}
    end

    def release_runtime(runtime_id) do
      send(self(), {:release_runtime, runtime_id})
      {:ok, runtime(%{runtime_id: runtime_id, status: "released"})}
    end

    def get_runtime_environment("missing") do
      send(self(), {:get_runtime_environment, "missing"})
      nil
    end

    def get_runtime_environment(runtime_id) do
      send(self(), {:get_runtime_environment, runtime_id})
      runtime(%{runtime_id: runtime_id})
    end

    def list_runtime_environments(opts) do
      send(self(), {:list_runtime_environments, opts})
      [runtime(%{status: opts[:status], runner_id: opts[:runner_id]})]
    end

    defp runtime(attrs) do
      %{
        runtime_id: Map.get(attrs, :runtime_id, "rt-1"),
        workspace_id: Map.get(attrs, :workspace_id, "workspace-1"),
        action_id: Map.get(attrs, :action_id, "act-1"),
        assignment_id: Map.get(attrs, :assignment_id, nil),
        runner_id: Map.get(attrs, :runner_id, "runner-1"),
        session_id: Map.get(attrs, :session_id, nil),
        host_name: Map.get(attrs, :host_name, "local"),
        status: Map.get(attrs, :status, "ready"),
        repo_path: "/repo",
        worktree_path: "/worktree",
        runtime_dir: "/runtime",
        branch: "jx/runtime",
        branch_isolation: Map.get(attrs, :branch_isolation, "worktree"),
        tools: Map.get(attrs, :tools, ["mix"]),
        capabilities: Map.get(attrs, :capabilities, ["elixir"]),
        os: Map.get(attrs, :os, "darwin"),
        concurrency_limit: Map.get(attrs, :concurrency_limit, 1),
        metadata: %{},
        next: "jx runtimes show #{Map.get(attrs, :runtime_id, "rt-1")}"
      }
    end

    defp assignment(attrs) do
      %{
        assignment_id: "asgn-1",
        action_id: Map.get(attrs, :action_id, "act-1"),
        approval_id: "apr-1",
        workspace_id: "workspace-1",
        safe_action_kind: "rerun_devide_command",
        status: "claimed",
        claimant_agent_id: nil,
        runner_id: Map.get(attrs, :runner_id, nil),
        session_id: Map.get(attrs, :session_id, nil),
        lease_id: "lease-1",
        correlation_id: "corr-1",
        summary: "Assignment summary"
      }
    end
  end

  test "runtimes provision owns parsing and json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Runtimes.run(
                   [
                     "provision",
                     "act-1",
                     "--project",
                     "saysure",
                     "--host",
                     "host-1",
                     "--runner",
                     "runner-1",
                     "--tool",
                     "mix",
                     "--tool",
                     "git",
                     "--capability",
                     "elixir",
                     "--os",
                     "darwin",
                     "--branch-isolation",
                     "worktree",
                     "--concurrency-limit",
                     "2",
                     "--ttl-seconds",
                     "300",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:provision_runtime_for_action, "act-1", opts}
    assert opts[:project] == "saysure"
    assert opts[:host] == "host-1"
    assert opts[:runner_id] == "runner-1"
    assert opts[:tools] == ["mix", "git"]
    assert opts[:capabilities] == ["elixir"]
    assert opts[:os] == "darwin"
    assert opts[:branch_isolation] == "worktree"
    assert opts[:concurrency_limit] == 2
    assert opts[:ttl_seconds] == 300

    assert %{"runtime" => %{"runtime_id" => "rt-1", "workspace_id" => "workspace-saysure"}} =
             Jason.decode!(output)
  end

  test "runtimes provision requires project before starting the app" do
    assert {:error, message} =
             Runtimes.run(["provision", "act-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "--project is required"
    refute_received :started
    refute_received :provision_runtime_for_action
  end

  test "runtimes provision validates concurrency before starting the app" do
    assert {:error, message} =
             Runtimes.run(
               ["provision", "act-1", "--project", "saysure", "--concurrency-limit", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "concurrency-limit must be a positive integer"
    refute_received :started
    refute_received :provision_runtime_for_action
  end

  test "runtimes assign routes runner session and ttl" do
    output =
      capture_io(fn ->
        assert :ok =
                 Runtimes.run(
                   [
                     "assign",
                     "rt-1",
                     "act-1",
                     "--runner",
                     "runner-1",
                     "--session",
                     "rsess-1",
                     "--ttl-seconds",
                     "600",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:assign_runtime_action, "rt-1", "act-1", opts}
    assert opts[:runner_id] == "runner-1"
    assert opts[:session_id] == "rsess-1"
    assert opts[:ttl_seconds] == 600

    assert %{
             "runtime" => %{"runtime_id" => "rt-1", "status" => "assigned"},
             "assignment" => %{"assignment_id" => "asgn-1", "runner_id" => "runner-1"}
           } = Jason.decode!(output)
  end

  test "runtimes assign validates ttl before starting the app" do
    assert {:error, message} =
             Runtimes.run(["assign", "rt-1", "act-1", "--ttl-seconds", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "ttl-seconds must be a positive integer"
    refute_received :started
    refute_received :assign_runtime_action
  end

  test "runtimes release calls workspace and renders stable text" do
    output =
      capture_io(fn ->
        assert :ok =
                 Runtimes.run(["release", "rt-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:release_runtime, "rt-1"}
    assert output =~ "released rt-1"
    assert output =~ "status"
    assert output =~ "released"
  end

  test "runtimes show renders json through workspace boundary" do
    output =
      capture_io(fn ->
        assert :ok =
                 Runtimes.run(["show", "rt-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:get_runtime_environment, "rt-1"}
    assert %{"runtime" => %{"runtime_id" => "rt-1"}} = Jason.decode!(output)
  end

  test "runtimes show reports missing runtime after starting the app" do
    assert {:error, :runtime_not_found} =
             Runtimes.run(["show", "missing"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert_received :started
    assert_received {:get_runtime_environment, "missing"}
  end

  test "runtimes ls owns filters and default status" do
    output =
      capture_io(fn ->
        assert :ok =
                 Runtimes.run(
                   [
                     "ls",
                     "--workspace",
                     "workspace-1",
                     "--runner",
                     "runner-1",
                     "-n",
                     "10",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:list_runtime_environments, opts}
    assert opts[:status] == "active"
    assert opts[:workspace_id] == "workspace-1"
    assert opts[:runner_id] == "runner-1"
    assert opts[:limit] == 10

    assert %{"runtimes" => [%{"runtime_id" => "rt-1", "status" => "active"}]} =
             Jason.decode!(output)
  end

  test "runtimes ls validates limit before starting the app" do
    assert {:error, message} =
             Runtimes.run(["ls", "-n", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "n must be a positive integer"
    refute_received :started
    refute_received :list_runtime_environments
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
