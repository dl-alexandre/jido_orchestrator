defmodule JX.CLI.SessionsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Sessions

  defmodule FakeWorkspace do
    def list_sessions(opts) do
      send(self(), {:list_sessions, opts})
      {:ok, %{sessions: [session()], errors: []}}
    end

    def snapshot_sessions(opts) do
      send(self(), {:snapshot_sessions, opts})
      {:ok, %{sessions: [Map.put(session(), :capture, capture())], errors: []}}
    end

    def record_session_observations(report) do
      send(self(), {:record_session_observations, report})
      {:ok, [%{id: 1}]}
    end

    def list_monitor_events(opts) do
      send(self(), {:list_monitor_events, opts})

      [
        %{
          id: 1,
          event_id: "evt-1",
          kind: "session.changed",
          severity: "notice",
          ref: "ref-1",
          project: "saysure",
          work_state: "running",
          action: "observe",
          summary: "changed",
          payload: "{}",
          inserted_at: "2026-05-12T00:00:00Z"
        }
      ]
    end

    def list_runner_sessions(opts) do
      send(self(), {:list_runner_sessions, opts})
      [runner_session()]
    end

    def get_runner_session(session_id) do
      send(self(), {:get_runner_session, session_id})
      runner_session(session_id)
    end

    def runner_session_logs(session_id, opts) do
      send(self(), {:runner_session_logs, session_id, opts})

      {:ok,
       %{
         session: runner_session(session_id),
         log_path: "/tmp/runner.log",
         tmux_server: "default",
         tmux_session_name: "jx_runner",
         note: "tail -n 25 /tmp/runner.log"
       }}
    end

    def runner_session_attach_plan(session_id) do
      send(self(), {:runner_session_attach_plan, session_id})

      {:ok,
       %{session: runner_session(session_id), command: "tmux attach -t jx_runner", note: "attach"}}
    end

    def expire_runner_sessions do
      send(self(), :expire_runner_sessions)
      [runner_session("session-2")]
    end

    defp session do
      %{
        ref: "ref-1",
        host: "local",
        transport: "local",
        type: "agent",
        state: "active",
        control_mode: "managed",
        server: "default",
        session: "jx_saysure",
        window: 0,
        pane: 1,
        kind: "codex",
        agent_name: "codex",
        task_id: "task-1",
        ssh_target: "",
        pid: 123,
        active: true,
        actions: "send",
        current_path: "/tmp/worktree",
        title: "work"
      }
    end

    defp capture do
      %{status: "ok", work_state: "running", output: "first line\nlast line\n"}
    end

    defp runner_session(session_id \\ "session-1") do
      %{
        session_id: session_id,
        runner_id: "runner-1",
        agent_id: "agent-1",
        assignment_id: "assignment-1",
        workspace_id: "workspace-1",
        action_id: "action-1",
        approval_id: "approval-1",
        status: "running",
        correlation_id: "corr-1",
        tmux_server: "default",
        tmux_session_name: "jx_runner",
        log_path: "/tmp/runner.log",
        last_summary: "working",
        heartbeat_at: "2026-05-12T00:00:00Z",
        expires_at: "2026-05-12T01:00:00Z"
      }
    end
  end

  test "bare sessions routes filters through the workspace boundary" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["--host", "local", "--type", "agent", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:list_sessions, opts}
    assert opts[:host_name] == "local"
    assert opts[:type] == "agent"
    assert opts[:all_tmux] == true
    assert %{"sessions" => [%{"ref" => "ref-1"}]} = Jason.decode!(output)
  end

  test "snapshot saves observations and compacts captured output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(
                   ["snapshot", "--managed", "-n", "12", "--save", "--compact", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:snapshot_sessions, opts}
    assert opts[:lines] == 12
    assert opts[:all_tmux] == false
    assert_received {:record_session_observations, %{sessions: [%{ref: "ref-1"}]}}

    assert %{
             "saved" => 1,
             "sessions" => [%{"capture" => %{"summary" => summary} = capture}]
           } = Jason.decode!(output)

    assert summary =~ "last line"
    refute Map.has_key?(capture, "output")
  end

  test "changed sessions uses monitor change kinds and renders events" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["changed", "--ref", "ref-1", "-n", "7", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:list_monitor_events, opts}
    assert opts[:ref] == "ref-1"
    assert opts[:limit] == 7
    assert "session.changed" in opts[:kinds]
    assert %{"events" => [%{"event_id" => "evt-1"}]} = Jason.decode!(output)
  end

  test "runner session commands route through the workspace boundary" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["ls", "--status", "active", "--runner", "runner-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )

        assert :ok =
                 Sessions.run(["show", "session-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )

        assert :ok =
                 Sessions.run(["logs", "session-1", "--lines", "25", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )

        assert :ok =
                 Sessions.run(["attach", "session-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )

        assert :ok =
                 Sessions.run(["expire", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:list_runner_sessions, opts}
    assert opts[:status] == "active"
    assert opts[:runner_id] == "runner-1"
    assert_received {:get_runner_session, "session-1"}
    assert_received {:runner_session_logs, "session-1", [lines: 25]}
    assert_received {:runner_session_attach_plan, "session-1"}
    assert_received :expire_runner_sessions
    assert output =~ ~s("sessions")
    assert output =~ ~s("session_id": "session-1")
    assert output =~ ~s("expired")
  end

  test "invalid options are rejected before starting the app" do
    assert {:error, message} =
             Sessions.run(["snapshot", "-n", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "n must be a positive integer"
    refute_received :started
    refute_received :snapshot_sessions
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
