defmodule JX.CLI.AssignmentsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Assignments

  defmodule FakeWorkspace do
    def create_assignment(action_id, opts) do
      send(self(), {:create_assignment, action_id, opts})
      {:ok, assignment(%{action_id: action_id, status: "created"})}
    end

    def list_assignments(opts) do
      send(self(), {:list_assignments, opts})

      [
        assignment(%{
          status: "claimed",
          claimant_agent_id: "agent-1",
          next: "jx assignments execute asgn-1 --agent <agent-id> --confirm"
        })
      ]
    end

    def claim_assignment(assignment_id, agent_id) do
      send(self(), {:claim_assignment, assignment_id, agent_id})

      {:ok,
       assignment(%{
         assignment_id: assignment_id,
         status: "claimed",
         claimant_agent_id: agent_id
       })}
    end

    def claim_runner_assignment(assignment_id, runner_id, opts) do
      send(self(), {:claim_runner_assignment, assignment_id, runner_id, opts})

      session =
        runner_session(%{
          assignment_id: assignment_id,
          runner_id: runner_id,
          session_id: opts[:session_id] || "rsess-1",
          tmux_session_name: opts[:tmux_session_name] || "jx-runner"
        })

      {:ok,
       %{
         assignment:
           assignment(%{
             assignment_id: assignment_id,
             status: "claimed",
             runner_id: runner_id,
             session_id: session.session_id
           }),
         session: session
       }}
    end

    def start_assignment(assignment_id, agent_id) do
      send(self(), {:start_assignment, assignment_id, agent_id})

      {:ok,
       assignment(%{
         assignment_id: assignment_id,
         status: "started",
         claimant_agent_id: agent_id
       })}
    end

    def progress_assignment(assignment_id, agent_id, summary) do
      send(self(), {:progress_assignment, assignment_id, agent_id, summary})

      {:ok,
       assignment(%{
         assignment_id: assignment_id,
         status: "progressed",
         claimant_agent_id: agent_id,
         summary: summary
       })}
    end

    def execute_assignment(assignment_id, agent_id, opts) do
      send(self(), {:execute_assignment, assignment_id, agent_id, opts})

      {:ok,
       assignment(%{
         assignment_id: assignment_id,
         status: "completed",
         claimant_agent_id: agent_id
       })}
    end

    def fail_assignment(assignment_id, agent_id, summary) do
      send(self(), {:fail_assignment, assignment_id, agent_id, summary})

      {:ok,
       assignment(%{
         assignment_id: assignment_id,
         status: "failed",
         claimant_agent_id: agent_id,
         summary: summary
       })}
    end

    def expire_assignments do
      send(self(), :expire_assignments)
      [assignment(%{assignment_id: "asgn-expired", status: "expired"})]
    end

    defp assignment(attrs) do
      %{
        assignment_id: Map.get(attrs, :assignment_id, "asgn-1"),
        action_id: Map.get(attrs, :action_id, "act-1"),
        approval_id: "apr-1",
        workspace_id: "workspace-1",
        safe_action_kind: "rerun_devide_command",
        status: Map.get(attrs, :status, "created"),
        claimant_agent_id: Map.get(attrs, :claimant_agent_id, nil),
        runner_id: Map.get(attrs, :runner_id, nil),
        session_id: Map.get(attrs, :session_id, nil),
        lease_id: nil,
        correlation_id: "corr-1",
        required_capabilities: ["elixir"],
        summary: Map.get(attrs, :summary, "Assignment summary"),
        next: Map.get(attrs, :next, "jx assignments claim asgn-1 --agent <agent-id>"),
        claimed_at: nil,
        started_at: nil,
        last_report_at: nil,
        completed_at: nil,
        expires_at: nil
      }
    end

    defp runner_session(attrs) do
      %{
        session_id: Map.get(attrs, :session_id, "rsess-1"),
        runner_id: Map.get(attrs, :runner_id, "runner-1"),
        agent_id: "agent-1",
        assignment_id: Map.get(attrs, :assignment_id, "asgn-1"),
        workspace_id: "workspace-1",
        action_id: "act-1",
        approval_id: "apr-1",
        status: "claimed",
        correlation_id: "corr-1",
        tmux_server: "jx",
        tmux_session_name: Map.get(attrs, :tmux_session_name, "jx-runner"),
        log_path: "/tmp/runner.log",
        last_summary: "",
        started_at: nil,
        heartbeat_at: nil,
        ended_at: nil,
        expires_at: nil,
        next: "jx sessions show #{Map.get(attrs, :session_id, "rsess-1")}"
      }
    end
  end

  test "assignments create owns parsing and json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Assignments.run(
                   [
                     "create",
                     "act-1",
                     "--created-by",
                     "operator-1",
                     "--ttl-seconds",
                     "300",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:create_assignment, "act-1", opts}
    assert opts[:created_by] == "operator-1"
    assert opts[:ttl_seconds] == 300

    assert %{"assignment_id" => "asgn-1", "action_id" => "act-1"} = Jason.decode!(output)
  end

  test "assignments create validates ttl before starting the app" do
    assert {:error, message} =
             Assignments.run(["create", "act-1", "--ttl-seconds", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "ttl-seconds must be a positive integer"
    refute_received :started
    refute_received :create_assignment
  end

  test "assignments ls owns filters and json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Assignments.run(
                   [
                     "ls",
                     "--status",
                     "active",
                     "--agent",
                     "agent-1",
                     "--workspace",
                     "workspace-1",
                     "-n",
                     "10",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:list_assignments, opts}
    assert opts[:status] == "active"
    assert opts[:agent_id] == "agent-1"
    assert opts[:workspace_id] == "workspace-1"
    assert opts[:limit] == 10

    assert %{"assignments" => [%{"assignment_id" => "asgn-1", "status" => "claimed"}]} =
             Jason.decode!(output)
  end

  test "assignments claim validates owner before starting the app" do
    assert {:error, message} =
             Assignments.run(["claim", "asgn-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "--agent or --runner is required"
    refute_received :started
    refute_received :claim_assignment
    refute_received :claim_runner_assignment
  end

  test "assignments claim rejects competing owners before starting the app" do
    assert {:error, message} =
             Assignments.run(["claim", "asgn-1", "--agent", "agent-1", "--runner", "runner-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "use either --agent or --runner, not both"
    refute_received :started
    refute_received :claim_assignment
    refute_received :claim_runner_assignment
  end

  test "assignments claim can route through runner sessions" do
    output =
      capture_io(fn ->
        assert :ok =
                 Assignments.run(
                   [
                     "claim",
                     "asgn-1",
                     "--runner",
                     "runner-1",
                     "--session",
                     "rsess-1",
                     "--tmux-session",
                     "jx-runner-1",
                     "--log-path",
                     "/tmp/runner.log"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:claim_runner_assignment, "asgn-1", "runner-1", opts}
    assert opts[:session_id] == "rsess-1"
    assert opts[:tmux_session_name] == "jx-runner-1"
    assert opts[:log_path] == "/tmp/runner.log"

    assert output =~ "claimed asgn-1"
    assert output =~ "runner: runner-1"
    assert output =~ "session: rsess-1"
    assert output =~ "tmux: jx/jx-runner-1"
  end

  test "assignments execute without confirm starts app but refuses side effect" do
    assert {:error, message} =
             Assignments.run(["execute", "asgn-1", "--agent", "agent-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "confirmation required; pass --confirm to execute this assignment"
    assert_received :started
    refute_received {:execute_assignment, _assignment_id, _agent_id, _opts}
  end

  test "assignments execute with confirm calls workspace" do
    output =
      capture_io(fn ->
        assert :ok =
                 Assignments.run(["execute", "asgn-1", "--agent", "agent-1", "--confirm"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:execute_assignment, "asgn-1", "agent-1", [confirm: true]}
    assert output =~ "executed asgn-1"
    assert output =~ "status: completed"
  end

  test "assignments progress requires summary before starting" do
    assert {:error, message} =
             Assignments.run(["progress", "asgn-1", "--agent", "agent-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "--summary is required"
    refute_received :started
    refute_received :progress_assignment
  end

  test "assignments expire renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Assignments.run(["expire", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received :expire_assignments

    assert %{"expired" => [%{"assignment_id" => "asgn-expired", "status" => "expired"}]} =
             Jason.decode!(output)
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
