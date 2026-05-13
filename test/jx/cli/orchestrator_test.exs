defmodule JX.CLI.OrchestratorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Orchestrator

  defmodule FakeDaemon do
    def start(opts) do
      send(self(), {:daemon_start, opts})

      {:ok,
       %{
         running: true,
         session_name: opts[:session_name],
         tmux_server: opts[:tmux_server],
         log_path: opts[:log_path],
         command: "jx orchestrate run"
       }}
    end

    def status(opts) do
      send(self(), {:daemon_status, opts})

      {:ok,
       %{
         running: false,
         session_name: opts[:session_name],
         tmux_server: opts[:tmux_server],
         log_path: opts[:log_path]
       }}
    end

    def stop(opts) do
      send(self(), {:daemon_stop, opts})

      {:ok,
       %{
         running: false,
         stopped: true,
         session_name: opts[:session_name],
         tmux_server: opts[:tmux_server],
         log_path: opts[:log_path]
       }}
    end

    def logs(opts) do
      send(self(), {:daemon_logs, opts})
      {:ok, %{output: "one\ntwo\n"}}
    end
  end

  defmodule FakeWorkspace do
    def orchestrator_health(opts) do
      send(self(), {:orchestrator_health, opts})

      %{
        generated_at: "2026-05-12T00:00:00Z",
        status: "ok",
        stale_after_seconds: opts[:stale_after_seconds],
        heartbeats_total: 1,
        alerts_total: 0,
        alerts: [],
        heartbeats: [heartbeat()]
      }
    end

    def orchestrator_decide(ref, attrs) do
      send(self(), {:orchestrator_decide, ref, attrs})
      {:ok, %{ref: ref, action: attrs.action, result_summary: "updated"}}
    end

    def list_orchestrator_heartbeats(opts) do
      send(self(), {:orchestrator_heartbeats, opts})

      if opts[:consumer] == "empty" do
        []
      else
        [heartbeat()]
      end
    end

    def orchestrator_inbox(opts) do
      send(self(), {:orchestrator_inbox, opts})

      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         observed: true,
         observation_refresh: %{saved: 1},
         total: 3,
         sections: %{
           needs_judgment: [inbox_item("ref-1")],
           delegation_reviews: [delegation_review()],
           recovery: %{recommendations: [recovery_recommendation()]},
           suggestions: [suggestion()],
           ready: [inbox_item("ref-2")],
           awaiting_observation: [],
           recently_completed: []
         },
         errors: [%{host: "test-host", transport: "ssh", subsystem: "tmux", error: "err"}]
       }}
    end

    def orchestrator_review(ref, _opts) do
      send(self(), {:orchestrator_review, ref})

      {:ok,
       %{
         ref: ref,
         generated_at: "2026-05-12T00:00:00Z",
         observed: true,
         observation_refresh: %{saved: 1},
         profile: %{
           session: %{project: "saysure"},
           comparison: %{state: "running", actual_summary: "ok"},
           next_prompt: %{status: "ready"},
           actual: %{work_state: "running"}
         },
         latest_observation: %{
           saved: 1,
           inserted_at: ~U[2026-05-12 00:00:00Z]
         },
         recommendation: %{
           type: "continue",
           safety: "safe",
           reason: "all good",
           prompt: "keep going",
           evidence: ["evidence one", "evidence two"]
         },
         commands: [
           %{action: "observe", command: "jx observe ref-1"},
           %{action: "prompt", command: "jx prompt ref-1 continue"}
         ],
         errors: []
       }}
    end

    defp heartbeat do
      %{
        daemon_key: "orch-1",
        consumer: "operator",
        session_name: "jx-orchestrator",
        status: "running",
        mode: "dry-run",
        last_scan_at: "2026-05-12T00:00:00Z",
        last_decision_at: "2026-05-12T00:01:00Z",
        last_error: "",
        next_wake_at: "2026-05-12T00:02:00Z",
        scan_snapshot:
          Jason.encode!(%{
            guidance: %{
              top_priority: "review",
              operator_needed_for: ["approval"]
            }
          }),
        updated_at: "2026-05-12T00:00:00Z"
      }
    end

    defp inbox_item(ref) do
      %{
        ref: ref,
        project: "saysure",
        state: "running",
        prompt_status: "ready",
        work_state: "running",
        next_step: "continue",
        actual: "working"
      }
    end

    defp delegation_review do
      %{
        delegation_id: "d1",
        decision: "approve",
        ref: "ref-1",
        project: "saysure",
        title: "title",
        summary: "summary"
      }
    end

    defp recovery_recommendation do
      %{
        action: "restart",
        safety: "safe",
        ref: "ref-1",
        target: "tmux pane p1",
        reason: "session stale",
        evidence: ["no heartbeat"]
      }
    end

    defp suggestion do
      %{
        ref: "ref-3",
        project: "saysure",
        safety: "safe",
        prompt_status: "draft",
        reason: "next step available",
        prompt: "continue implementation"
      }
    end
  end

  test "start parses daemon and orchestration options through injectable daemon" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   [
                     "start",
                     "--session",
                     "orch",
                     "--server",
                     "jx",
                     "--log",
                     "/tmp/orch.log",
                     "--replace",
                     "--dry-run",
                     "--consumer",
                     "operator",
                     "--host",
                     "local",
                     "--managed",
                     "--all-processes",
                     "--type",
                     "agent",
                     "--ssh-target",
                     "build-1",
                     "--work-state",
                     "running",
                     "--control",
                     "managed",
                     "--prompt-status",
                     "ready",
                     "--no-observe",
                     "--lines",
                     "40",
                     "--scan-limit",
                     "9",
                     "--queue-limit",
                     "8",
                     "--event-limit",
                     "7",
                     "--decision-limit",
                     "6",
                     "--min-observe-age-seconds",
                     "5",
                     "--interval-ms",
                     "4",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   database_path: fn -> "/tmp/jx.db" end,
                   daemon: FakeDaemon
                 )
      end)

    assert_received :started
    assert_received {:daemon_start, opts}
    assert opts[:session_name] == "orch"
    assert opts[:tmux_server] == "jx"
    assert opts[:log_path] == "/tmp/orch.log"
    assert opts[:db_path] == "/tmp/jx.db"
    assert opts[:replace] == true
    assert opts[:dry_run] == true
    assert opts[:consumer] == "operator"
    assert opts[:host_name] == "local"
    assert opts[:all_tmux] == false
    assert opts[:all_processes] == true
    assert opts[:type] == "agent"
    assert opts[:ssh_target] == "build-1"
    assert opts[:work_state] == "running"
    assert opts[:control_mode] == "managed"
    assert opts[:prompt_status] == "ready"
    assert opts[:observe] == false
    assert opts[:lines] == 40
    assert opts[:scan_limit] == 9
    assert opts[:queue_limit] == 8
    assert opts[:event_limit] == 7
    assert opts[:decision_limit] == 6
    assert opts[:min_observe_age_seconds] == 5
    assert opts[:interval_ms] == 4
    assert opts[:execute] == true
    assert opts[:yes] == true
    assert opts[:ack] == true
    assert opts[:auto_plan] == true

    assert %{"running" => true, "session_name" => "orch"} = Jason.decode!(output)
  end

  test "health validates filters and renders json through injectable workspace" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   [
                     "health",
                     "--consumer",
                     "operator",
                     "--status",
                     "running",
                     "--stale-after-seconds",
                     "90",
                     "-n",
                     "3",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:orchestrator_health, opts}
    assert opts == [consumer: "operator", status: "running", stale_after_seconds: 90, limit: 3]

    assert %{
             "status" => "ok",
             "stale_after_seconds" => 90,
             "heartbeats" => [%{"guidance" => %{"top_priority" => "review"}}]
           } = Jason.decode!(output)
  end

  test "decide validates one action before starting the app" do
    assert {:error, message} =
             Orchestrator.run(
               ["decide", "ref-1", "--prompt", "continue", "--hold", "blocked"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "choose exactly one decision action"
    refute_received :started
    refute_received {:orchestrator_decide, _ref, _attrs}
  end

  test "status delegates to daemon without starting the application" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["status", "--session", "orch", "--server", "jx", "--log", "/tmp/orch.log"],
                   start_app: start_app_callback(),
                   daemon: FakeDaemon
                 )
      end)

    refute_received :started
    assert_received {:daemon_status, opts}
    assert opts[:session_name] == "orch"
    assert output =~ "orchestrator stopped"
  end

  test "status renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["status", "--session", "orch", "--json"],
                   start_app: start_app_callback(),
                   daemon: FakeDaemon
                 )
      end)

    refute_received :started
    decoded = Jason.decode!(output)
    assert decoded["running"] == false
    assert decoded["session_name"] == "orch"
  end

  test "stop delegates to daemon and renders text" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["stop", "--session", "orch", "--server", "jx"],
                   start_app: start_app_callback(),
                   daemon: FakeDaemon
                 )
      end)

    refute_received :started
    assert_received {:daemon_stop, opts}
    assert opts[:session_name] == "orch"
    assert output =~ "orchestrator stopped"
  end

  test "stop renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["stop", "--session", "orch", "--json"],
                   start_app: start_app_callback(),
                   daemon: FakeDaemon
                 )
      end)

    decoded = Jason.decode!(output)
    assert decoded["running"] == false
    assert decoded["stopped"] == true
  end

  test "logs delegates to daemon and renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["logs", "--session", "orch", "--server", "jx", "-n", "10"],
                   start_app: start_app_callback(),
                   daemon: FakeDaemon
                 )
      end)

    refute_received :started
    assert_received {:daemon_logs, opts}
    assert opts[:lines] == 10
    assert output == "one\ntwo\n"
  end

  test "logs renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["logs", "--session", "orch", "--json"],
                   start_app: start_app_callback(),
                   daemon: FakeDaemon
                 )
      end)

    decoded = Jason.decode!(output)
    assert decoded["output"] == "one\ntwo\n"
  end

  test "heartbeats validates filters and renders text" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["heartbeats", "--consumer", "operator", "--status", "running", "-n", "5"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:orchestrator_heartbeats, opts}
    assert opts == [consumer: "operator", status: "running", limit: 5]
    assert output =~ "orch-1"
    assert output =~ "running"
    assert output =~ "operator"
  end

  test "heartbeats renders empty text" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["heartbeats", "--consumer", "empty"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert output =~ "no orchestrator heartbeats"
  end

  test "heartbeats renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["heartbeats", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    decoded = Jason.decode!(output)
    assert [%{"daemon_key" => "orch-1"}] = decoded["heartbeats"]
  end

  test "heartbeats renders empty json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["heartbeats", "--consumer", "empty", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    decoded = Jason.decode!(output)
    assert decoded["heartbeats"] == []
  end

  test "health renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["health", "--consumer", "operator"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "orchestrator health"
    assert output =~ "ok"
  end

  test "inbox renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["inbox", "--host", "local", "--type", "agent", "--managed"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:orchestrator_inbox, opts}
    assert opts[:host_name] == "local"
    assert opts[:type] == "agent"
    assert opts[:all_tmux] == false
    assert output =~ "orchestrator inbox"
    assert output =~ "needs judgment"
    assert output =~ "delegation reviews"
    assert output =~ "recovery recommendations"
    assert output =~ "planner suggestions"
    assert output =~ "ready / chambered"
    assert output =~ "test-host"
    assert output =~ "err"
  end

  test "inbox renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["inbox", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    decoded = Jason.decode!(output)
    assert decoded["total"] == 3
    assert get_in(decoded, ["sections", "needs_judgment"]) |> length() == 1
  end

  test "review renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["review", "ref-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:orchestrator_review, "ref-1"}
    assert output =~ "orchestrator review ref-1"
    assert output =~ "latest observation"
    assert output =~ "recommendation"
    assert output =~ "evidence"
    assert output =~ "commands"
  end

  test "review renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["review", "ref-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    decoded = Jason.decode!(output)
    assert decoded["ref"] == "ref-1"
    assert get_in(decoded, ["recommendation", "type"]) == "continue"
    assert get_in(decoded, ["latest_observation", "saved"]) == 1
  end

  test "decide prompt with ready renders text" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["decide", "ref-1", "--prompt", "continue", "--ready"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:orchestrator_decide, "ref-1", attrs}
    assert attrs.action == "prompt"
    assert attrs.prompt == "continue"
    assert attrs.prompt_status == "ready"
    assert output =~ "updated: ref-1"
  end

  test "decide prompt with draft renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrator.run(
                   ["decide", "ref-1", "--prompt", "continue", "--draft", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    decoded = Jason.decode!(output)
    assert decoded["ref"] == "ref-1"
    assert decoded["action"] == "prompt"
  end

  test "decide hold renders text" do
    capture_io(fn ->
      assert :ok =
               Orchestrator.run(
                 ["decide", "ref-1", "--hold", "blocked", "--note", "waiting on dependency"],
                 start_app: start_app_callback(),
                 workspace: FakeWorkspace
               )
    end)

    assert_received {:orchestrator_decide, "ref-1", attrs}
    assert attrs.action == "hold"
    assert attrs.reason == "blocked"
    assert attrs.notes == "waiting on dependency"
  end

  test "decide clear renders text" do
    capture_io(fn ->
      assert :ok =
               Orchestrator.run(
                 ["decide", "ref-1", "--clear"],
                 start_app: start_app_callback(),
                 workspace: FakeWorkspace
               )
    end)

    assert_received {:orchestrator_decide, "ref-1", attrs}
    assert attrs.action == "clear"
  end

  test "decide ignore renders text" do
    capture_io(fn ->
      assert :ok =
               Orchestrator.run(
                 ["decide", "ref-1", "--ignore"],
                 start_app: start_app_callback(),
                 workspace: FakeWorkspace
               )
    end)

    assert_received {:orchestrator_decide, "ref-1", attrs}
    assert attrs.action == "ignore"
  end

  test "decide protect renders text" do
    capture_io(fn ->
      assert :ok =
               Orchestrator.run(
                 ["decide", "ref-1", "--protect"],
                 start_app: start_app_callback(),
                 workspace: FakeWorkspace
               )
    end)

    assert_received {:orchestrator_decide, "ref-1", attrs}
    assert attrs.action == "protect"
  end

  test "decide managed renders text" do
    capture_io(fn ->
      assert :ok =
               Orchestrator.run(
                 ["decide", "ref-1", "--managed"],
                 start_app: start_app_callback(),
                 workspace: FakeWorkspace
               )
    end)

    assert_received {:orchestrator_decide, "ref-1", attrs}
    assert attrs.action == "managed"
  end

  test "decide validates ready and draft are mutually exclusive" do
    assert {:error, message} =
             Orchestrator.run(
               ["decide", "ref-1", "--prompt", "continue", "--ready", "--draft"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "use either --ready or --draft"
    refute_received :started
    refute_received {:orchestrator_decide, _ref, _attrs}
  end

  test "decide validates exactly one action" do
    assert {:error, message} =
             Orchestrator.run(
               ["decide", "ref-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "choose exactly one decision action"
  end

  test "invalid command returns usage error" do
    assert {:error, message} =
             Orchestrator.run(["invalid"], start_app: start_app_callback())

    assert message =~ "usage:"
    refute_received :started
  end

  test "missing start_app callback returns error" do
    assert {:error, :missing_start_app_callback} =
             Orchestrator.run(["health"], workspace: FakeWorkspace)
  end

  test "start validates invalid type" do
    assert {:error, message} =
             Orchestrator.run(
               ["start", "--type", "bad"],
               start_app: start_app_callback(),
               daemon: FakeDaemon
             )

    assert message =~ "unsupported session type"
    refute_received :started
  end

  test "start validates invalid work_state" do
    assert {:error, message} =
             Orchestrator.run(
               ["start", "--work-state", "bad"],
               start_app: start_app_callback(),
               daemon: FakeDaemon
             )

    assert message =~ "unsupported work state"
    refute_received :started
  end

  test "start validates invalid control" do
    assert {:error, message} =
             Orchestrator.run(
               ["start", "--control", "bad"],
               start_app: start_app_callback(),
               daemon: FakeDaemon
             )

    assert message =~ "unsupported session control mode"
    refute_received :started
  end

  test "start validates invalid prompt_status" do
    assert {:error, message} =
             Orchestrator.run(
               ["start", "--prompt-status", "bad"],
               start_app: start_app_callback(),
               daemon: FakeDaemon
             )

    assert message =~ "unsupported prompt status"
    refute_received :started
  end

  test "heartbeats validates invalid status" do
    assert {:error, message} =
             Orchestrator.run(
               ["heartbeats", "--status", "bad"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported heartbeat status"
    refute_received :started
  end

  test "health validates stale-after-seconds must be positive" do
    assert {:error, "stale-after-seconds must be a positive integer"} =
             Orchestrator.run(
               ["health", "--stale-after-seconds", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    refute_received :started
  end

  test "health validates n must be positive" do
    assert {:error, "n must be a positive integer"} =
             Orchestrator.run(
               ["health", "-n", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    refute_received :started
  end

  test "logs validates n must be positive" do
    assert {:error, "n must be a positive integer"} =
             Orchestrator.run(
               ["logs", "-n", "0"],
               start_app: start_app_callback(),
               daemon: FakeDaemon
             )

    refute_received :started
  end

  test "inbox validates lines must be positive" do
    assert {:error, "lines must be a positive integer"} =
             Orchestrator.run(
               ["inbox", "--lines", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    refute_received :started
  end

  test "inbox validates scan-limit must be positive" do
    assert {:error, "scan-limit must be a positive integer"} =
             Orchestrator.run(
               ["inbox", "--scan-limit", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    refute_received :started
  end

  test "inbox validates n must be positive" do
    assert {:error, "n must be a positive integer"} =
             Orchestrator.run(
               ["inbox", "-n", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    refute_received :started
  end

  test "review validates lines must be positive" do
    assert {:error, "lines must be a positive integer"} =
             Orchestrator.run(
               ["review", "ref-1", "--lines", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    refute_received :started
  end

  test "start validates min-observe-age-seconds must be non-negative" do
    assert {:error, "min-observe-age-seconds must be a non-negative integer"} =
             Orchestrator.run(
               ["start", "--min-observe-age-seconds", "-1"],
               start_app: start_app_callback(),
               daemon: FakeDaemon
             )

    refute_received :started
  end

  test "start validates interval-ms must be positive" do
    assert {:error, "interval-ms must be a positive integer"} =
             Orchestrator.run(
               ["start", "--interval-ms", "0"],
               start_app: start_app_callback(),
               daemon: FakeDaemon
             )

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
