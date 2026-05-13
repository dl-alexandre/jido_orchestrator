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

    def session_summary(opts) do
      send(self(), {:session_summary, opts})

      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         registry: %{warnings: []},
         current: %{total: 1},
         observations: %{total: 1},
         observation_refresh: %{total: 1},
         reconciliation: %{
           current_observed_total: 1,
           current_unobserved_total: 0,
           observed_missing_total: 0,
           current_unobserved: [],
           observed_missing: []
         },
         remote: %{total: 1},
         workflow: %{clusters_total: 1, clusters: [], remote_targets: [], recommendations: []},
         attention: [],
         stale: [],
         errors: []
       }}
    end

    def observe_sessions(opts) do
      send(self(), {:observe_sessions, opts})

      {:ok,
       %{
         changes: [session_change()],
         saved: 1
       }}
    end

    def session_profiles(opts) do
      send(self(), {:session_profiles, opts})

      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         observed: 1,
         observation_refresh: %{total: 1},
         operator: %{
           key: "op-1",
           source: "test",
           name: "Test",
           preferences: "",
           working_style: "",
           escalation_policy: "",
           notes: "",
           updated_at: nil
         },
         total: 1,
         profiles: [session_profile()],
         errors: []
       }}
    end

    def session_queues(opts) do
      send(self(), {:session_queues, opts})

      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         observed: 1,
         observation_refresh: %{total: 1},
         total: 1,
         queues_total: 1,
         queues: [
           %{
             action: "send",
             total: 1,
             by_priority: %{high: 1},
             by_safety: %{safe: 1},
             by_control: %{managed: 1},
             by_type: %{agent: 1},
             items: [%{ref: "ref-1", task: "work", current_path: "/tmp", pane: "default/jx:0.1"}]
           }
         ],
         errors: []
       }}
    end

    def session_dossiers(opts) do
      send(self(), {:session_dossiers, opts})

      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         observed: 1,
         observation_refresh: %{total: 1},
         total: 1,
         dossiers: [
           %{
             ref: "ref-1",
             control_mode: "managed",
             type: "agent",
             kind: "codex",
             work_state: "running",
             next_action: %{action: "send"},
             directive_state: "ready",
             repo: %{
               present: true,
               branch: "main",
               ahead: 0,
               behind: 0,
               dirty: false,
               changes: 0,
               blockers: [],
               risks: []
             },
             project: "saysure",
             pane: "default/jx:0.1",
             current_path: "/tmp/worktree",
             task: "coverage"
           }
         ],
         errors: []
       }}
    end

    def session_reconciliation(opts) do
      send(self(), {:session_reconciliation, opts})

      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         totals: %{total: 1},
         orphan_remote: [],
         local_without_remote: [],
         duplicate_paths: [],
         errors: []
       }}
    end

    def recovery_plan(opts) do
      send(self(), {:recovery_plan, opts})

      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         status: "ok",
         counts: %{total: 1},
         recommendations: []
       }}
    end

    def list_session_observations(opts) do
      send(self(), {:list_session_observations, opts})

      [
        %{
          id: 1,
          ref: "ref-1",
          host: "local",
          transport: "local",
          type: "agent",
          state: "active",
          kind: "codex",
          agent_name: "codex",
          task_id: "task-1",
          tmux_server: "default",
          session_name: "jx_saysure",
          window: 0,
          pane: 1,
          pid: 123,
          ssh_target: "",
          work_state: "running",
          capture_status: "ok",
          summary: "working",
          snapshot: "{}",
          inserted_at: "2026-05-12T00:00:00Z"
        }
      ]
    end

    def list_session_changes(opts) do
      send(self(), {:list_session_changes, opts})

      [
        %{
          ref: "ref-1",
          host: "local",
          transport: "local",
          type: "agent",
          state: "active",
          kind: "codex",
          agent_name: "codex",
          task_id: "task-1",
          tmux_server: "default",
          session_name: "jx_saysure",
          window: 0,
          pane: 1,
          pid: 123,
          ssh_target: "",
          work_state: "running",
          previous_work_state: "waiting",
          capture_status: "ok",
          previous_capture_status: "ok",
          summary: "working",
          previous_summary: "waiting",
          observed_at: "2026-05-12T00:00:00Z",
          previous_observed_at: "2026-05-12T00:00:00Z",
          elapsed_seconds: 60,
          change: "work_state",
          changed_fields: ["work_state"],
          needs_attention: false
        }
      ]
    end

    def list_stale_session_observations(opts) do
      send(self(), {:list_stale_session_observations, opts})

      [
        %{
          ref: "ref-1",
          host: "local",
          transport: "local",
          type: "agent",
          state: "active",
          kind: "codex",
          agent_name: "codex",
          task_id: "task-1",
          tmux_server: "default",
          session_name: "jx_saysure",
          window: 0,
          pane: 1,
          pid: 123,
          ssh_target: "",
          work_state: "running",
          capture_status: "ok",
          summary: "working",
          observed_at: "2026-05-12T00:00:00Z",
          stale_seconds: 600,
          needs_attention: false
        }
      ]
    end

    def broadcast_sessions(message, opts) do
      send(self(), {:broadcast_sessions, message, opts})

      {:ok,
       %{
         dry_run: true,
         targets: [
           %{
             ref: "ref-1",
             status: "ok",
             host: "local",
             type: "agent",
             kind: "codex",
             work_state: "running",
             tmux_server: "default",
             session_name: "jx_saysure",
             window: 0,
             pane: 1,
             summary: "working",
             directive_id: "dir-1"
           }
         ],
         errors: []
       }}
    end

    def remote_session_candidates(opts) do
      send(self(), {:remote_session_candidates, opts})

      {:ok,
       [
         %{
           target: "ssh-target-1",
           registered_host: "remote-1",
           pid: 1234,
           server: "default",
           session: "remote",
           window: 0,
           pane: 1,
           current_path: "/remote",
           title: "remote work"
         }
       ]}
    end

    def probe_remote_sessions(opts) do
      send(self(), {:probe_remote_sessions, opts})

      {:ok,
       [
         %{
           ssh_target: "ssh-target-1",
           registered_host: "remote-1",
           pid: 1234,
           target: "default/remote:0.1",
           status: "ok",
           tmux: "default/remote",
           sessions: 1,
           detail: "ok",
           remote_sessions: [
             %{
               server: "default",
               session: "remote",
               created_at: "2026-05-12T00:00:00Z",
               attached: 1,
               windows: 2,
               current_path: "/remote"
             }
           ]
         }
       ]}
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

    defp session_change do
      %{
        ref: "ref-1",
        host: "local",
        transport: "local",
        type: "agent",
        state: "active",
        kind: "codex",
        agent_name: "codex",
        task_id: "task-1",
        tmux_server: "default",
        session_name: "jx_saysure",
        window: 0,
        pane: 1,
        pid: 123,
        ssh_target: "",
        work_state: "running",
        previous_work_state: "waiting",
        capture_status: "ok",
        previous_capture_status: "ok",
        summary: "working",
        previous_summary: "waiting",
        observed_at: "2026-05-12T00:00:00Z",
        previous_observed_at: "2026-05-12T00:00:00Z",
        elapsed_seconds: 60,
        change: "work_state",
        changed_fields: ["work_state"],
        needs_attention: false
      }
    end

    defp session_profile do
      %{
        ref: "ref-1",
        comparison: %{state: "ok", actual_summary: "working"},
        coordination: %{mode: "managed", operator_needed: false},
        planned: %{prompt_status: "ready", expected_completion: "soon", objective: "test"},
        session: %{control_mode: "managed"},
        actual: %{work_state: "running"},
        next_step: "continue"
      }
    end
  end

  # -- existing tests with json output remain, plus text variants --

  test "bare sessions routes filters through the workspace boundary with json" do
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

  test "bare sessions renders text table output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["--host", "local", "--type", "agent"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "REF"
    assert output =~ "ref-1"
    assert output =~ "HOST"
    assert output =~ "local"
  end

  test "snapshot saves observations and compacts captured output with json" do
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

  test "snapshot renders text table output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(
                   ["snapshot", "--managed", "-n", "12"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "REF"
    assert output =~ "ref-1"
    assert output =~ "CAPTURE"
  end

  test "snapshot with empty sessions prints no sessions text" do
    defmodule FakeWorkspaceEmptySnapshot do
      def snapshot_sessions(_opts), do: {:ok, %{sessions: [], errors: []}}
    end

    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(
                   ["snapshot", "--managed"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspaceEmptySnapshot
                 )
      end)

    assert output =~ "no sessions"
  end

  test "changed sessions uses monitor change kinds and renders events with json" do
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

  test "changed sessions renders text table output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["changed", "--ref", "ref-1", "-n", "7"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:list_monitor_events, _opts}
    assert output =~ "ID"
    assert output =~ "session.changed"
    assert output =~ "KIND"
  end

  test "changed with no events prints no monitor events text" do
    defmodule FakeWorkspaceEmptyEvents do
      def list_monitor_events(_opts), do: []
    end

    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["changed", "--ref", "ref-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspaceEmptyEvents
                 )
      end)

    assert output =~ "no monitor events"
  end

  test "runner session commands route through the workspace boundary with json" do
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

  test "runner session commands render text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["ls", "--status", "active", "--runner", "runner-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )

        assert :ok =
                 Sessions.run(["show", "session-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )

        assert :ok =
                 Sessions.run(["logs", "session-1", "--lines", "25"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )

        assert :ok =
                 Sessions.run(["attach", "session-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )

        assert :ok =
                 Sessions.run(["expire"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "ID"
    assert output =~ "session-1"
    assert output =~ "status: running"
    assert output =~ "log_path:"
    assert output =~ "command:"
    assert output =~ "expired 1 runner session"
  end

  test "runner expire with no sessions prints no sessions text" do
    defmodule FakeWorkspaceEmptyRunner do
      def expire_runner_sessions, do: []
    end

    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["expire"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspaceEmptyRunner
                 )
      end)

    assert output =~ "expired 0 runner sessions"
  end

  # -- uncovered subcommand tests --

  test "summary renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["summary", "--host", "local", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:session_summary, opts}
    assert opts[:host_name] == "local"
    assert %{"generated_at" => _} = Jason.decode!(output)
  end

  test "summary renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["summary", "--host", "local"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "generated"
    assert output =~ "registry"
    assert output =~ "current"
  end

  test "observe renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["observe", "--host", "local", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:observe_sessions, opts}
    assert opts[:host_name] == "local"
    assert %{"saved" => 1, "changes" => [%{"ref" => "ref-1"}]} = Jason.decode!(output)
  end

  test "observe renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["observe", "--host", "local"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "OBSERVED"
    assert output =~ "ref-1"
    assert output =~ "saved 1 observations"
  end

  test "ready renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["ready", "--host", "local", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:session_profiles, opts}
    assert opts[:host_name] == "local"
    assert opts[:prompt_status] == "ready"
    assert %{"profiles" => [%{"ref" => "ref-1"}]} = Jason.decode!(output)
  end

  test "ready renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["ready", "--host", "local"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "REF"
    assert output =~ "ref-1"
    assert output =~ "PROMPT"
  end

  test "queues renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["queues", "--host", "local", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:session_queues, opts}
    assert opts[:host_name] == "local"
    assert %{"queues" => [%{"action" => "send"}]} = Jason.decode!(output)
  end

  test "queues renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["queues", "--host", "local"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "ACTION"
    assert output =~ "send"
    assert output =~ "TOTAL"
  end

  test "dossiers renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["dossiers", "--ref", "ref-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:session_dossiers, opts}
    assert opts[:ref] == "ref-1"
    assert %{"dossiers" => [%{"ref" => "ref-1"}]} = Jason.decode!(output)
  end

  test "dossiers renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["dossiers", "--ref", "ref-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "REF"
    assert output =~ "ref-1"
    assert output =~ "NEXT"
  end

  test "profiles renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["profiles", "--ref", "ref-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:session_profiles, opts}
    assert opts[:ref] == "ref-1"
    assert %{"profiles" => [%{"ref" => "ref-1"}]} = Jason.decode!(output)
  end

  test "profiles renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["profiles", "--ref", "ref-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "REF"
    assert output =~ "ref-1"
    assert output =~ "STATE"
  end

  test "reconcile renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["reconcile", "--host", "local", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:session_reconciliation, opts}
    assert opts[:host_name] == "local"
    assert %{"generated_at" => _} = Jason.decode!(output)
  end

  test "reconcile renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["reconcile", "--host", "local"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "session reconciliation"
    assert output =~ "generated:"
  end

  test "recover renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["recover", "--host", "local", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:recovery_plan, opts}
    assert opts[:host_name] == "local"
    assert %{"status" => "ok"} = Jason.decode!(output)
  end

  test "recover renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["recover", "--host", "local"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "session recovery"
    assert output =~ "status: ok"
  end

  test "history renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["history", "--ref", "ref-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:list_session_observations, opts}
    assert opts[:ref] == "ref-1"
    assert %{"observations" => [%{"ref" => "ref-1"}]} = Jason.decode!(output)
  end

  test "history renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["history", "--ref", "ref-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "OBSERVED"
    assert output =~ "ref-1"
  end

  test "history with no observations prints no session observations text" do
    defmodule FakeWorkspaceEmptyHistory do
      def list_session_observations(_opts), do: []
    end

    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["history", "--ref", "ref-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspaceEmptyHistory
                 )
      end)

    assert output =~ "no session observations"
  end

  test "changes renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["changes", "--ref", "ref-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:list_session_changes, opts}
    assert opts[:ref] == "ref-1"
    assert %{"changes" => [%{"ref" => "ref-1"}]} = Jason.decode!(output)
  end

  test "changes renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["changes", "--ref", "ref-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "OBSERVED"
    assert output =~ "ref-1"
    assert output =~ "CHANGE"
  end

  test "changes with no changes prints no session changes text" do
    defmodule FakeWorkspaceEmptyChanges do
      def list_session_changes(_opts), do: []
    end

    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["changes", "--ref", "ref-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspaceEmptyChanges
                 )
      end)

    assert output =~ "no session changes"
  end

  test "stale renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["stale", "--ref", "ref-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:list_stale_session_observations, opts}
    assert opts[:ref] == "ref-1"
    assert %{"stale" => [%{"ref" => "ref-1"}]} = Jason.decode!(output)
  end

  test "stale renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["stale", "--ref", "ref-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "REF"
    assert output =~ "ref-1"
    assert output =~ "STALE_S"
  end

  test "stale with no stale sessions prints no stale session observations text" do
    defmodule FakeWorkspaceEmptyStale do
      def list_stale_session_observations(_opts), do: []
    end

    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["stale", "--ref", "ref-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspaceEmptyStale
                 )
      end)

    assert output =~ "no stale session observations"
  end

  test "broadcast renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(
                   ["broadcast", "hello world", "--host", "local", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:broadcast_sessions, "hello world", opts}
    assert opts[:host_name] == "local"
    assert %{"targets" => [%{"ref" => "ref-1"}]} = Jason.decode!(output)
  end

  test "broadcast renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(
                   ["broadcast", "hello world", "--host", "local"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "dry run: pass --yes to send"
    assert output =~ "REF"
    assert output =~ "ref-1"
  end

  test "broadcast with empty message returns usage error" do
    assert {:error, message} =
             Sessions.run(["broadcast", "--host", "local"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage:"
    refute_received :started
  end

  test "remote candidates renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["remote", "--target", "ssh-target-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:remote_session_candidates, opts}
    assert opts[:target] == "ssh-target-1"
    assert %{"candidates" => [%{"target" => "ssh-target-1"}]} = Jason.decode!(output)
  end

  test "remote candidates renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["remote", "--target", "ssh-target-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "SSH_TARGET"
    assert output =~ "ssh-target-1"
  end

  test "remote probe renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(
                   ["remote", "--target", "ssh-target-1", "--probe", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:probe_remote_sessions, opts}
    assert opts[:target] == "ssh-target-1"
    assert %{"probes" => [%{"ssh_target" => "ssh-target-1"}]} = Jason.decode!(output)
  end

  test "remote probe renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(
                   ["remote", "--target", "ssh-target-1", "--probe"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "SSH_TARGET"
    assert output =~ "ssh-target-1"
    assert output =~ "STATUS"
  end

  # -- error path tests --

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

  test "invalid session type is rejected before starting the app" do
    assert {:error, message} =
             Sessions.run(["--type", "invalid"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported session type"
    refute_received :started
  end

  test "invalid work state is rejected before starting the app" do
    assert {:error, message} =
             Sessions.run(["snapshot", "--work-state", "invalid"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported work state"
    refute_received :started
  end

  test "invalid severity is rejected before starting the app" do
    assert {:error, message} =
             Sessions.run(["changed", "--severity", "invalid"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported monitor severity"
    refute_received :started
  end

  test "invalid runner session status is rejected before starting the app" do
    assert {:error, message} =
             Sessions.run(["ls", "--status", "invalid"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported session status"
    refute_received :started
  end

  test "invalid control mode is rejected before starting the app" do
    assert {:error, message} =
             Sessions.run(["ready", "--control", "invalid"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported session control mode"
    refute_received :started
  end

  test "invalid prompt status is rejected before starting the app" do
    assert {:error, message} =
             Sessions.run(["profiles", "--prompt-status", "invalid"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported prompt status"
    refute_received :started
  end

  test "invalid next action is rejected before starting the app" do
    assert {:error, message} =
             Sessions.run(["dossiers", "--next", "invalid"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported dossier next action"
    refute_received :started
  end

  test "show returns error when runner session not found" do
    defmodule FakeWorkspaceMissingRunner do
      def get_runner_session(_session_id), do: nil
    end

    assert {:error, :runner_session_not_found} =
             Sessions.run(["show", "missing", "--json"],
               start_app: start_app_callback(),
               workspace: FakeWorkspaceMissingRunner
             )

    assert_received :started
  end

  test "reconcile renders text with orphan remote and duplicate paths" do
    defmodule FakeWorkspaceReconcileFull do
      def session_reconciliation(_opts) do
        {:ok,
         %{
           generated_at: "2026-05-12T00:00:00Z",
           totals: %{total: 2},
           orphan_remote: [
             %{
               local_ref: "ref-1",
               ssh_target: "target-1",
               tmux_server: "default",
               session_name: "jx",
               current_path: "/repo",
               observed_at: "2026-05-12T00:00:00Z"
             }
           ],
           local_without_remote: [
             %{
               ref: "ref-2",
               project: "saysure",
               type: "agent",
               kind: "codex",
               state: "active",
               prompt_status: "ready",
               path: "/repo",
               next_step: "continue"
             }
           ],
           duplicate_paths: [
             %{
               path: "/repo",
               projects: ["saysure"],
               refs: ["ref-1", "ref-2"]
             }
           ],
           errors: []
         }}
      end
    end

    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["reconcile", "--host", "local"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspaceReconcileFull
                 )
      end)

    assert output =~ "orphan remote sessions"
    assert output =~ "local without remote match"
    assert output =~ "duplicate paths"
    assert output =~ "ref-1"
    assert output =~ "ref-2"
  end

  test "recover renders text with recommendations" do
    defmodule FakeWorkspaceRecoverFull do
      def recovery_plan(_opts) do
        {:ok,
         %{
           generated_at: "2026-05-12T00:00:00Z",
           status: "attention",
           counts: %{total: 1},
           recommendations: [
             %{
               action: "restart",
               safety: "safe",
               ref: "ref-1",
               target: "session-1",
               reason: "stale",
               evidence: ["no heartbeat"]
             }
           ]
         }}
      end
    end

    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["recover", "--host", "local"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspaceRecoverFull
                 )
      end)

    assert output =~ "session recovery"
    assert output =~ "status: attention"
    assert output =~ "recovery recommendations"
    assert output =~ "restart"
    assert output =~ "ref-1"
  end

  test "broadcast with empty targets renders appropriate text" do
    defmodule FakeWorkspaceBroadcastEmpty do
      def broadcast_sessions(_message, _opts) do
        {:ok, %{dry_run: true, targets: [], errors: []}}
      end
    end

    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(
                   ["broadcast", "hello", "--host", "local"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspaceBroadcastEmpty
                 )
      end)

    assert output =~ "no sendable targets"
  end

  test "broadcast without dry run and empty targets renders text" do
    defmodule FakeWorkspaceBroadcastSent do
      def broadcast_sessions(_message, _opts) do
        {:ok, %{dry_run: false, targets: [], errors: []}}
      end
    end

    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(
                   ["broadcast", "hello", "--host", "local", "--yes"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspaceBroadcastSent
                 )
      end)

    assert output =~ "no targets sent"
  end

  test "bare sessions with empty results prints no sessions text" do
    defmodule FakeWorkspaceEmptySessions do
      def list_sessions(_opts) do
        {:ok, %{sessions: [], errors: []}}
      end
    end

    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["--host", "local"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspaceEmptySessions
                 )
      end)

    assert output =~ "no sessions"
  end

  test "remote candidates with empty list prints no ssh panes" do
    defmodule FakeWorkspaceEmptyRemote do
      def remote_session_candidates(_opts), do: {:ok, []}
    end

    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["remote", "--target", "none"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspaceEmptyRemote
                 )
      end)

    assert output =~ "no ssh panes"
  end

  test "remote probe with empty list prints no ssh panes" do
    defmodule FakeWorkspaceEmptyProbe do
      def probe_remote_sessions(_opts), do: {:ok, []}
    end

    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(
                   ["remote", "--target", "none", "--probe"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspaceEmptyProbe
                 )
      end)

    assert output =~ "no ssh panes"
  end

  test "summary with attention and stale sections prints them" do
    defmodule FakeWorkspaceSummaryFull do
      def session_summary(_opts) do
        {:ok,
         %{
           generated_at: "2026-05-12T00:00:00Z",
           registry: %{warnings: ["stale host"]},
           current: %{total: 1},
           observations: %{total: 1},
           observation_refresh: %{total: 1},
           reconciliation: %{
             current_observed_total: 1,
             current_unobserved_total: 0,
             observed_missing_total: 0,
             current_unobserved: [],
             observed_missing: []
           },
           remote: %{total: 1},
           workflow: %{clusters_total: 0, clusters: [], remote_targets: [], recommendations: []},
           attention: [
             %{
               ref: "ref-1",
               host: "local",
               transport: "local",
               type: "agent",
               state: "active",
               kind: "codex",
               agent_name: "codex",
               task_id: "task-1",
               tmux_server: "default",
               session_name: "jx_saysure",
               window: 0,
               pane: 1,
               pid: 123,
               ssh_target: "",
               work_state: "running",
               previous_work_state: "waiting",
               capture_status: "ok",
               previous_capture_status: "ok",
               summary: "working",
               previous_summary: "waiting",
               observed_at: "2026-05-12T00:00:00Z",
               previous_observed_at: "2026-05-12T00:00:00Z",
               elapsed_seconds: 60,
               change: "work_state",
               changed_fields: ["work_state"],
               needs_attention: true
             }
           ],
           stale: [
             %{
               ref: "ref-1",
               host: "local",
               transport: "local",
               type: "agent",
               state: "active",
               kind: "codex",
               agent_name: "codex",
               task_id: "task-1",
               tmux_server: "default",
               session_name: "jx_saysure",
               window: 0,
               pane: 1,
               pid: 123,
               ssh_target: "",
               work_state: "running",
               capture_status: "ok",
               summary: "working",
               observed_at: "2026-05-12T00:00:00Z",
               stale_seconds: 600,
               needs_attention: false
             }
           ],
           errors: []
         }}
      end
    end

    output =
      capture_io(fn ->
        assert :ok =
                 Sessions.run(["summary", "--host", "local"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspaceSummaryFull
                 )
      end)

    assert output =~ "attention"
    assert output =~ "stale"
    assert output =~ "warnings: stale host"
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
