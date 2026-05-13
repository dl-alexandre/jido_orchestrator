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
      [heartbeat()]
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

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
