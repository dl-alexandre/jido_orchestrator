defmodule JX.CLI.ProjectTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Project

  defmodule FakeWorkspace do
    def add_project(attrs) do
      send(self(), {:add_project, attrs})
      {:ok, Map.merge(%{slug: attrs.name}, attrs)}
    end

    def list_projects do
      [
        %{
          name: "saysure",
          slug: "saysure",
          repo_path: "/repo/saysure",
          host: %{
            name: "local",
            transport: "local",
            ssh_target: nil,
            workspace_path: "/workspace"
          }
        }
      ]
    end

    def project_audit(name, opts) do
      send(self(), {:project_audit, name, opts})

      {:ok,
       %{
         project: name,
         summary: %{total: 1, dirty: 0},
         warnings: [],
         instances: [
           %{
             host: "local",
             status: "ok",
             branch: "main",
             head: "abcdef123456",
             upstream: "origin/main",
             ahead: 0,
             behind: 0,
             dirty: false,
             changes: [],
             warnings: [],
             repo_path: "/repo/saysure"
           }
         ]
       }}
    end

    def project_gate(name) do
      send(self(), {:project_gate, name})

      {:ok,
       %{
         project: name,
         eligible: false,
         status: "blocked",
         hosts: [%{host: "local", status: "blocked", reasons: ["push_not_verified"]}],
         required_fixes: ["Restore GitHub auth."]
       }}
    end

    def project_brief(name, opts) do
      send(self(), {:project_brief, name, opts})

      {:ok,
       %{
         project: %{name: name},
         headline: "Project status",
         next: %{next: "inspect", command: "jx project brief #{name}"},
         mode: %{id: "tui", title: "Terminal UI"},
         counts: %{notifications: 1},
         refs: [],
         agenda: []
       }}
    end
  end

  test "project add owns argument parsing and output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Project.run(["add", "saysure", "--host", "local", "--repo", "/repo/saysure"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output == "project saysure registered: host=local repo=/repo/saysure\n"
    assert_received :started

    assert_received {:add_project,
                     %{name: "saysure", host_name: "local", repo_path: "/repo/saysure"}}
  end

  test "project audit passes host option and renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Project.run(["audit", "saysure", "--host", "local", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:project_audit, "saysure", [host_name: "local"]}

    decoded = Jason.decode!(output)
    assert decoded["project_audit"]["project"] == "saysure"
  end

  test "project gate renders blocked hosts" do
    output =
      capture_io(fn ->
        assert :ok =
                 Project.run(["gate", "saysure"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:project_gate, "saysure"}
    assert output =~ "Promotion eligible: no"
    assert output =~ "push_not_verified"
    assert output =~ "Restore GitHub auth."
  end

  test "project brief validates before starting the app" do
    assert {:error, message} =
             Project.run(["brief", "saysure", "--type", "bad-type"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported session type"
    refute_received :started
  end

  test "project brief passes normalized options" do
    output =
      capture_io(fn ->
        assert :ok =
                 Project.run(
                   [
                     "brief",
                     "saysure",
                     "--host",
                     "local",
                     "--managed",
                     "--all-processes",
                     "--type",
                     "tmux",
                     "--ssh-target",
                     "dev@example.test",
                     "--work-state",
                     "running",
                     "--control",
                     "managed",
                     "--no-observe",
                     "--lines",
                     "42",
                     "--scan-limit",
                     "120",
                     "-n",
                     "7",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:project_brief, "saysure", opts}
    assert opts[:host_name] == "local"
    assert opts[:all_tmux] == false
    assert opts[:all_processes] == true
    assert opts[:type] == "tmux"
    assert opts[:ssh_target] == "dev@example.test"
    assert opts[:work_state] == "running"
    assert opts[:control_mode] == "managed"
    assert opts[:observe] == false
    assert opts[:lines] == 42
    assert opts[:scan_limit] == 120
    assert opts[:limit] == 7

    decoded = Jason.decode!(output)
    assert decoded["project_brief"]["project"]["name"] == "saysure"
  end

  test "project ls json normalizes registered projects" do
    output =
      capture_io(fn ->
        assert :ok =
                 Project.run(["ls", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started

    assert %{
             "projects" => [
               %{
                 "name" => "saysure",
                 "host" => "local",
                 "transport" => "local",
                 "repo_path" => "/repo/saysure",
                 "workspace_path" => "/workspace"
               }
             ]
           } = Jason.decode!(output)
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
