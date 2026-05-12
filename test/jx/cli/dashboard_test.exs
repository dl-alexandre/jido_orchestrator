defmodule JX.CLI.DashboardTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Dashboard

  defmodule FakeWorkspace do
    def operator_dashboard(opts) do
      send(self(), {:operator_dashboard, opts})
      root_report()
    end

    def operator_dashboard_workspace(workspace_id, opts) do
      send(self(), {:operator_dashboard_workspace, workspace_id, opts})

      %{
        workspace_id: workspace_id,
        generated_at: "2026-05-12T00:00:00Z",
        health: %{status: "attention", freshness: "stale", risk: "stale"},
        approvals: [],
        actions: [],
        assignments: [],
        runner_sessions: [],
        leases: [],
        timeline: %{events: []},
        next: %{queue: "jx queue workspace #{workspace_id}"}
      }
    end

    def operator_dashboard_runner(runner_id, opts) do
      send(self(), {:operator_dashboard_runner, runner_id, opts})

      {:ok,
       %{
         runner_id: runner_id,
         generated_at: "2026-05-12T00:00:00Z",
         runner: %{status: "active", host_name: "local", stale: false, active_sessions: 1},
         sessions: [],
         assignments: [],
         reports: [],
         timeline: %{events: []},
         next: %{sessions: "jx sessions ls --runner #{runner_id}"}
       }}
    end

    def operator_dashboard_assignment(assignment_id, opts) do
      send(self(), {:operator_dashboard_assignment, assignment_id, opts})

      {:ok,
       %{
         assignment_id: assignment_id,
         generated_at: "2026-05-12T00:00:00Z",
         assignment: %{
           status: "claimed",
           workspace_id: "workspace-1",
           action_id: "act-1",
           runner_id: "runner-1",
           session_id: "session-1",
           correlation_id: "corr-1"
         },
         replay: %{status: "pending", devide_assignment_id: nil, failure_class: nil},
         reports: [],
         runner_reports: [],
         failure_chain: [],
         timeline: %{events: []},
         next: %{assignment: "jx assignments show #{assignment_id}"}
       }}
    end

    def operator_dashboard_action(action_id, opts) do
      send(self(), {:operator_dashboard_action, action_id, opts})

      {:ok,
       %{
         action_id: action_id,
         generated_at: "2026-05-12T00:00:00Z",
         action: %{
           action_id: action_id,
           safe_action: "rerun_devide_command",
           status: "planned",
           outcome: nil,
           approval_id: "apr-1"
         },
         approval: %{
           approval_id: "apr-1",
           status: "open",
           kind: "safe_action",
           severity: "warning"
         },
         execution_events: [],
         assignments: [],
         reconciliation: %{items: []},
         timeline: %{events: []},
         next: %{action: "jx actions show #{action_id}"}
       }}
    end

    defp root_report do
      %{
        generated_at: "2026-05-12T00:00:00Z",
        queue: %{totals: %{total: 1, stale: 1}},
        workspaces: %{total: 1, stale: 1, blocked: 0},
        runner_fleet: %{total: 1, stale: 0, busy: 0, active_sessions: 1},
        runtime_environments: %{total: 1, ready: 1, assigned: 0, stale: 0},
        leases: %{total: 1, active: [%{lease_id: "lease-1"}], stale: [], terminal: []},
        assignments: %{total: 1, active: [%{assignment_id: "asgn-1"}], terminal: [], failed: []},
        reconciliation: %{total: 0, pending: 0, succeeded: 0, failed: 0},
        failures: %{assignments: []},
        recent_events: [],
        next: %{queue: "jx queue ls --sort urgency"}
      }
    end
  end

  test "dashboard owns root limits and json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Dashboard.run(
                   [
                     "--stale-after-seconds",
                     "120",
                     "--events",
                     "7",
                     "-n",
                     "9",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:operator_dashboard, opts}
    assert opts[:stale_after_seconds] == 120
    assert opts[:event_limit] == 7
    assert opts[:limit] == 9

    assert %{"queue" => %{"totals" => %{"total" => 1}}} = Jason.decode!(output)
  end

  test "dashboard validates limit before starting the app" do
    assert {:error, message} =
             Dashboard.run(["--n", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "n must be a positive integer"
    refute_received :started
    refute_received :operator_dashboard
  end

  test "dashboard workspace routes id and freshness window" do
    output =
      capture_io(fn ->
        assert :ok =
                 Dashboard.run(
                   [
                     "workspace",
                     "workspace-1",
                     "--stale-after-seconds",
                     "300",
                     "--events",
                     "4",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:operator_dashboard_workspace, "workspace-1", opts}
    assert opts[:stale_after_seconds] == 300
    assert opts[:event_limit] == 4

    assert %{"workspace_id" => "workspace-1"} = Jason.decode!(output)
  end

  test "dashboard runner routes limit and event window" do
    output =
      capture_io(fn ->
        assert :ok =
                 Dashboard.run(
                   ["runner", "runner-1", "--events", "6", "-n", "8", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:operator_dashboard_runner, "runner-1", opts}
    assert opts[:event_limit] == 6
    assert opts[:limit] == 8

    assert %{"runner_id" => "runner-1"} = Jason.decode!(output)
  end

  test "dashboard assignment and action preserve ok tuple contracts" do
    assignment_output =
      capture_io(fn ->
        assert :ok =
                 Dashboard.run(
                   ["assignment", "asgn-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:operator_dashboard_assignment, "asgn-1", opts}
    assert opts[:limit] == 100
    assert opts[:event_limit] == 25
    assert %{"assignment_id" => "asgn-1"} = Jason.decode!(assignment_output)

    action_output =
      capture_io(fn ->
        assert :ok =
                 Dashboard.run(
                   ["action", "act-1", "--events", "5", "-n", "3", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:operator_dashboard_action, "act-1", opts}
    assert opts[:limit] == 3
    assert opts[:event_limit] == 5
    assert %{"action_id" => "act-1"} = Jason.decode!(action_output)
  end

  test "unknown dashboard command returns focused usage" do
    assert {:error, message} =
             Dashboard.run(["unknown"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message ==
             "usage: jx dashboard [--stale-after-seconds 900] [--events 25] [-n 50] [--json]"

    refute_received :started
  end

  defp start_app_callback do
    fn ->
      send(self(), :started)
      :ok
    end
  end
end
