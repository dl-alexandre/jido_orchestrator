defmodule JX.CLI.FanoutTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Fanout

  defmodule FakeFanout do
    def plan(plan_id, opts) do
      send(self(), {:plan, plan_id, opts})

      {:ok,
       %{
         run_id: opts[:run_id] || plan_id,
         run_path: "/fanout/#{opts[:run_id] || plan_id}",
         manifest_path: "/fanout/#{opts[:run_id] || plan_id}/run_manifest.json",
         assignment_count: 1,
         assignment_ids: ["coverage-01"]
       }}
    end

    def preflight(run_ref, opts) do
      send(self(), {:preflight, run_ref, opts})

      {:ok,
       %{
         run_id: run_ref,
         run_path: "/fanout/#{run_ref}",
         result: "pass",
         assignments: [
           %{
             assignment_id: "coverage-01",
             host: "local",
             state: "planned",
             publishability: "publishable",
             failed_checks: []
           }
         ]
       }}
    end

    def launch(run_ref, target, opts) do
      send(self(), {:launch, run_ref, target, opts})

      {:ok,
       %{
         run_id: run_ref,
         run_path: "/fanout/#{run_ref}",
         assignments: [
           %{
             assignment_id: "coverage-01",
             state: "running",
             agent_id: "agent-1",
             session_name: "jx_fanout",
             assignment_start_commit: "abcdef123456",
             goal_status: "active"
           }
         ]
       }}
    end

    def monitor(run_ref, opts) do
      send(self(), {:monitor, run_ref, opts})

      {:ok,
       %{
         run_id: run_ref,
         run_path: "/fanout/#{run_ref}",
         assignments: [
           %{
             assignment_id: "coverage-01",
             derived_state: "running",
             completion_state: "open",
             ci_watch: %{"watch_id" => "watch-1", "status" => "pending"}
           }
         ]
       }}
    end

    def ownership_check(run_ref, assignment_id, opts) do
      send(self(), {:ownership_check, run_ref, assignment_id, opts})

      {:ok,
       %{
         "assignment_id" => assignment_id,
         "status" => "warn",
         "warnings" => ["outside write ownership"],
         "outside_write_paths" => ["lib/outside.ex"],
         "forbidden_touches" => []
       }}
    end

    def open_pr(run_ref, assignment_id, opts) do
      send(self(), {:open_pr, run_ref, assignment_id, opts})

      {:ok,
       %{
         assignment_id: assignment_id,
         state: "opened",
         pr: %{"url" => "https://github.test/pull/1"},
         ci_watch: nil
       }}
    end

    def accept_report(run_ref, report_attrs) do
      send(self(), {:accept_report, run_ref, report_attrs})

      {:ok, %{status: :accepted, path: "/fanout/#{run_ref}/reports/coverage-01/accepted/test.json"}}
    end

    def status(run_ref, opts) do
      send(self(), {:status, run_ref, opts})

      {:ok,
       %{
         run_id: run_ref,
         run_path: "/fanout/#{run_ref}",
         counts: %{planned: 1},
         assignments: [
           %{
             assignment_id: "coverage-01",
             host: "local",
             branch: "jx/coverage-01",
             orchestration_state: "planned",
             derived_state: "ready",
             completion_state: "open",
             report_count: 2
           }
         ]
       }}
    end
  end

  test "fanout plan owns parsing without starting the app" do
    output =
      capture_io(fn ->
        assert :ok =
                 Fanout.run(
                   [
                     "plan",
                     "coverage",
                     "--baseline",
                     "abc123",
                     "--base-branch",
                     "develop",
                     "--repo",
                     "owner/repo",
                     "--root",
                     "/tmp/fanout",
                     "--run-id",
                     "run-1",
                     "--coverage-file",
                     "coverage.csv",
                     "--host-count",
                     "2",
                     "--risk-rules",
                     "rules.json",
                     "--host",
                     "local=/repo,/worktrees,mix test",
                     "--host",
                     "build=/repo,/build,mix precommit"
                   ],
                   fanout: FakeFanout,
                   start_app: start_app_callback()
                 )
      end)

    assert output =~ "fanout run planned"
    assert output =~ "coverage-01"
    refute_received :started

    assert_received {:plan, "coverage", opts}
    assert opts[:baseline] == "abc123"
    assert opts[:base_branch] == "develop"
    assert opts[:repo] == "owner/repo"
    assert opts[:root] == "/tmp/fanout"
    assert opts[:run_id] == "run-1"
    assert opts[:coverage_file] == "coverage.csv"
    assert opts[:host_count] == 2
    assert opts[:risk_rules] == "rules.json"
    assert opts[:host] == ["local=/repo,/worktrees,mix test", "build=/repo,/build,mix precommit"]
  end

  test "fanout plan requires baseline before adapter calls" do
    assert {:error, message} =
             Fanout.run(["plan", "coverage"],
               fanout: FakeFanout,
               start_app: start_app_callback()
             )

    assert message =~ "usage: jx fanout plan"
    refute_received :plan
    refute_received :started
  end

  test "fanout launch validates target shape before adapter calls" do
    assert {:error, message} =
             Fanout.run(["launch", "run-1", "one", "two"],
               fanout: FakeFanout,
               start_app: start_app_callback()
             )

    assert message =~ "usage: jx fanout launch"
    refute_received :launch
    refute_received :started
  end

  test "fanout launch passes explicit assignment and launch options" do
    output =
      capture_io(fn ->
        assert :ok =
                 Fanout.run(
                   [
                     "launch",
                     "run-1",
                     "coverage-01",
                     "--root",
                     "/tmp/fanout",
                     "--lease-timeout-seconds",
                     "30",
                     "--agent",
                     "codex",
                     "--agent-bin",
                     "/bin/codex",
                     "--tmux-server",
                     "jx"
                   ],
                   fanout: FakeFanout,
                   start_app: start_app_callback()
                 )
      end)

    assert output =~ "fanout launch run-1"
    refute_received :started

    assert_received {:launch, "run-1", "coverage-01", opts}
    assert opts[:root] == "/tmp/fanout"
    assert opts[:lease_timeout_seconds] == 30
    assert opts[:agent] == "codex"
    assert opts[:agent_bin] == "/bin/codex"
    assert opts[:tmux_server] == "jx"
  end

  test "fanout monitor starts the app and renders text" do
    output =
      capture_io(fn ->
        assert :ok =
                 Fanout.run(["monitor", "run-1", "--root", "/tmp/fanout"],
                   fanout: FakeFanout,
                   start_app: start_app_callback()
                 )
      end)

    assert_received :started
    assert_received {:monitor, "run-1", [root: "/tmp/fanout"]}
    assert output =~ "fanout monitor run-1"
    assert output =~ "watch-1"
  end

  test "fanout pr starts the app and respects ci watch switch" do
    output =
      capture_io(fn ->
        assert :ok =
                 Fanout.run(
                   [
                     "pr",
                     "run-1",
                     "coverage-01",
                     "--root",
                     "/tmp/fanout",
                     "--repo",
                     "owner/repo",
                     "--no-register-ci-watch",
                     "--ci-watch-mode",
                     "hold",
                     "--allow-unvalidated"
                   ],
                   fanout: FakeFanout,
                   start_app: start_app_callback()
                 )
      end)

    assert_received :started
    assert_received {:open_pr, "run-1", "coverage-01", opts}
    assert opts[:root] == "/tmp/fanout"
    assert opts[:repo] == "owner/repo"
    assert opts[:register_ci_watch] == false
    assert opts[:ci_watch_mode] == "hold"
    assert opts[:allow_unvalidated] == true
    assert output =~ "fanout PR coverage-01"
  end

  test "fanout status renders json through the adapter boundary" do
    output =
      capture_io(fn ->
        assert :ok =
                 Fanout.run(["status", "run-1", "--root", "/tmp/fanout", "--json"],
                   fanout: FakeFanout,
                   start_app: start_app_callback()
                 )
      end)

    refute_received :started
    assert_received {:status, "run-1", [root: "/tmp/fanout"]}

    decoded = Jason.decode!(output)
    assert decoded["run_id"] == "run-1"
    assert decoded["counts"]["planned"] == 1
  end

  test "fanout report parses and submits a report without starting the app" do
    output =
      capture_io(fn ->
        assert :ok =
                 Fanout.run(
                   [
                     "report",
                     "run-1",
                     "--root",
                     "/tmp/fanout",
                     "--assignment-id",
                     "coverage-01",
                     "--report-id",
                     "rpt-1",
                     "--agent-id",
                     "agent-1",
                     "--sequence",
                     "1",
                     "--state",
                     "in_progress",
                     "--data",
                     ~s({"branch":"test/coverage-01"})
                   ],
                   fanout: FakeFanout,
                   start_app: start_app_callback()
                 )
      end)

    refute_received :started
    assert_received {:accept_report, "run-1", report_attrs}
    assert report_attrs[:assignment_id] == "coverage-01"
    assert report_attrs[:report_id] == "rpt-1"
    assert report_attrs[:agent_id] == "agent-1"
    assert report_attrs[:sequence] == 1
    assert report_attrs[:state] == "in_progress"
    assert report_attrs[:data]["branch"] == "test/coverage-01"
    assert output =~ "fanout report accepted"
  end

  test "fanout ownership passes warn-only and renders warnings" do
    output =
      capture_io(fn ->
        assert :ok =
                 Fanout.run(
                   ["ownership", "run-1", "coverage-01", "--root", "/tmp/fanout", "--warn-only"],
                   fanout: FakeFanout,
                   start_app: start_app_callback()
                 )
      end)

    refute_received :started
    assert_received {:ownership_check, "run-1", "coverage-01", opts}
    assert opts[:root] == "/tmp/fanout"
    assert opts[:warn_only] == true
    assert output =~ "outside write ownership"
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
