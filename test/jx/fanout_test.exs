defmodule JX.FanoutTest do
  use ExUnit.Case, async: true

  alias JX.Fanout

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "jx-fanout-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root}
  end

  test "public state lists and plan validation branches", %{root: root} do
    assert "planned" in Fanout.control_states()
    assert "complete" in Fanout.agent_states()

    assert {:error, "unknown fanout plan \"missing\""} = Fanout.plan("missing", [])
    assert {:error, "baseline is required"} = Fanout.plan("test-coverage", root: root)

    assert {:ok, _result} =
             Fanout.plan("test-coverage",
               baseline: "53907e03",
               root: root,
               run_id: "duplicate-run"
             )

    assert {:error, "fanout run already exists: " <> _} =
             Fanout.plan("test-coverage",
               baseline: "53907e03",
               root: root,
               run_id: "duplicate-run"
             )

    assert {:error, "coverage modules cannot be empty"} =
             Fanout.plan("coverage-dynamic",
               baseline: "53907e03",
               root: root,
               run_id: "empty-dynamic",
               coverage_modules: []
             )

    assert {:error, "host-count must be positive"} =
             Fanout.plan("coverage-dynamic",
               baseline: "53907e03",
               root: root,
               run_id: "bad-host-count",
               coverage_modules: [%{path: "lib/one/api/token.ex"}],
               host_count: 0
             )

    assert {:error, "could not read coverage file" <> _} =
             Fanout.plan("coverage-dynamic",
               baseline: "53907e03",
               root: root,
               run_id: "missing-coverage",
               coverage_file: Path.join(root, "missing.csv")
             )

    invalid_file = Path.join(root, "invalid-coverage.json")
    File.write!(invalid_file, Jason.encode!(%{"modules" => %{}}))

    assert {:error, "coverage file must be a JSON list" <> _} =
             Fanout.plan("coverage-dynamic",
               baseline: "53907e03",
               root: root,
               run_id: "invalid-coverage",
               coverage_file: invalid_file
             )
  end

  test "plan writes the fanout contract artifacts", %{root: root} do
    assert {:ok, result} =
             Fanout.plan("test-coverage",
               baseline: "53907e03",
               root: root,
               run_id: "test-coverage-test"
             )

    assert result.assignment_count == 5
    assert "auth-api-security" in result.assignment_ids

    manifest = read_json!(Path.join(result.run_path, "run_manifest.json"))
    assert manifest["repo"] == "example-project"
    assert manifest["baseline"] == "53907e03"
    assert "dry_run_push_passes" in manifest["publishability_contract"]["required"]
    assert "no_verify_push" in manifest["publishability_contract"]["agent_forbidden"]

    assignment =
      read_json!(Path.join([result.run_path, "assignments", "auth-api-security.json"]))

    assert assignment["state"] == "planned"
    assert assignment["excluded"] == false
    assert assignment["intent"]["branch"] == "test/auth-api-security-coverage"
    assert assignment["resolved_environment"]["host"] == "build-1"
    assert assignment["resolved_environment"]["assignment_start_commit"] == nil

    assert File.dir?(Path.join([result.run_path, "reports", "auth-api-security", "accepted"]))
    assert File.dir?(Path.join([result.run_path, "reports", "auth-api-security", "rejected"]))

    packet = File.read!(Path.join(result.run_path, "agent_packet.md"))
    assert packet =~ "This workflow is independent of `CLI-Tools`"
    assert packet =~ "`jx` is the control plane"
  end

  test "status reduces assignment records and accepted reports", %{root: root} do
    {:ok, result} =
      Fanout.plan("test-coverage",
        baseline: "53907e03",
        root: root,
        run_id: "test-coverage-status"
      )

    assert {:ok, status} = Fanout.status(result.run_path)
    assert status.counts["planned"] == 5

    assert {:ok, %{status: :accepted}} =
             Fanout.accept_report(result.run_path, %{
               report_id: "2026-05-08T12-05-00Z-in_progress",
               assignment_id: "auth-api-security",
               agent_id: "codex-s-test",
               sequence: 1,
               previous_report_id: nil,
               state: "in_progress",
               reported_at: "2026-05-08T12:05:00Z",
               data: %{"branch" => "test/auth-api-security-coverage"}
             })

    assert {:ok, status} = Fanout.status(result.run_path)
    assert status.counts["in_progress"] == 1
    assert status.counts["planned"] == 4

    assert %{derived_state: "in_progress", report_count: 1} =
             Enum.find(status.assignments, &(&1.assignment_id == "auth-api-security"))
  end

  test "preflight records concrete checks and launch requires every assignment to pass", %{
    root: root
  } do
    {:ok, result} =
      Fanout.plan("test-coverage",
        baseline: "53907e03",
        root: root,
        run_id: "test-coverage-preflight"
      )

    runner = fn assignment, script ->
      assert script =~ "expected_head"
      assert script =~ "dry_run_push_passes"

      if assignment["assignment_id"] == "liveview-ui" do
        {:error, {:command_failed, 1, preflight_output("expected_head")}}
      else
        {:ok, preflight_output()}
      end
    end

    assert {:ok, preflight} = Fanout.preflight(result.run_path, runner: runner)
    assert preflight.result == "fail"

    liveview = Enum.find(preflight.assignments, &(&1.assignment_id == "liveview-ui"))
    assert liveview.publishability == "fail"
    assert liveview.failed_checks == ["expected_head"]

    assert {:error, {:preflight_required, ["liveview-ui"]}} =
             Fanout.launch(result.run_path, :all,
               runner: fn _assignment, _script -> {:ok, ""} end
             )
  end

  test "launch creates a lease and Codex goal command from fresh preflight", %{root: root} do
    {:ok, result} =
      Fanout.plan("test-coverage",
        baseline: "53907e03",
        root: root,
        run_id: "test-coverage-launch"
      )

    assert {:ok, %{result: "pass"}} =
             Fanout.preflight(result.run_path,
               runner: fn _assignment, _script -> {:ok, preflight_output()} end
             )

    parent = self()

    runner = fn assignment, script ->
      assert script =~ "--goal"
      assert script =~ "goal_status.json"
      assert script =~ "goal_completion.json"
      assert script =~ "worktree add -B \"$branch\" \"$worktree\" \"$baseline\""
      send(parent, {:launch_script, assignment["assignment_id"], script})

      {:ok,
       """
       JX_LAUNCH\tassignment_start_commit\t53907e03
       JX_LAUNCH\tagent_id\tcodex-test
       JX_LAUNCH\tsession_name\tjx_fanout_test
       JX_LAUNCH\tgoal_path\t/tmp/goal.md
       JX_LAUNCH\tgoal_status_path\t/tmp/goal_status.json
       """}
    end

    assert {:ok, launch} = Fanout.launch(result.run_path, "auth-api-security", runner: runner)

    assert [%{assignment_id: "auth-api-security", state: "launching", goal_status: "requested"}] =
             launch.assignments

    assert_received {:launch_script, "auth-api-security", _script}

    assignment =
      read_json!(Path.join([result.run_path, "assignments", "auth-api-security.json"]))

    assert assignment["state"] == "launching"
    assert assignment["launch"]["lease_timeout_seconds"] == 86_400
    assert assignment["launch"]["goal_objective"] =~ "Expand coverage"
    assert assignment["launch"]["goal_status_path"] == "/tmp/goal_status.json"
    assert assignment["resolved_environment"]["assignment_start_commit"] == "53907e03"
  end

  test "ownership check rejects forbidden and outside-scope diffs", %{root: root} do
    {:ok, result} =
      Fanout.plan("test-coverage",
        baseline: "53907e03",
        root: root,
        run_id: "test-coverage-ownership"
      )

    assert {:error, {:ownership_failed, review}} =
             Fanout.ownership_check(result.run_path, "auth-api-security",
               diff_paths: [
                 "test/one/api/token_test.exs",
                 "lib/one_web/live/dashboard_live.ex",
                 "README.md"
               ]
             )

    assert review["outside_write_paths"] == ["README.md"]
    assert review["forbidden_touches"] == ["lib/one_web/live/dashboard_live.ex"]
    assert "diff touches forbidden paths" in review["warnings"]
  end

  test "open_pr runs ownership gate and registers a CI watch", %{root: root} do
    {:ok, result} =
      Fanout.plan("test-coverage",
        baseline: "53907e03",
        root: root,
        run_id: "test-coverage-pr"
      )

    assert {:ok, %{status: :accepted}} =
             Fanout.accept_report(result.run_path, %{
               report_id: "2026-05-08T12-05-00Z-local",
               assignment_id: "auth-api-security",
               agent_id: "codex-s-test",
               sequence: 1,
               previous_report_id: nil,
               state: "local_validated",
               reported_at: "2026-05-08T12:05:00Z",
               data: %{"validation" => "passed"}
             })

    runner = fn _assignment, script ->
      cond do
        script =~ "diff --name-only" ->
          {:ok, "test/one/api/token_test.exs\n"}

        script =~ "gh pr create" ->
          {:ok,
           """
           JX_PR\turl\thttps://github.com/acme-corp/example-project/pull/700
           JX_PR\thead_sha\tabcdef123456
           """}
      end
    end

    ci_watch_fun = fn attrs ->
      assert attrs.repo == "acme-corp/example-project"
      assert attrs.pr_number == 700

      {:ok,
       %{watch_id: "ciw-test", status: "active", repo: attrs.repo, pr_number: attrs.pr_number}}
    end

    assert {:ok, pr} =
             Fanout.open_pr(result.run_path, "auth-api-security",
               runner: runner,
               repo: "acme-corp/example-project",
               ci_watch_fun: ci_watch_fun
             )

    assert pr.state == "ci_pending"
    assert pr.ci_watch["watch_id"] == "ciw-test"

    assert {:ok, status} = Fanout.status(result.run_path)
    row = Enum.find(status.assignments, &(&1.assignment_id == "auth-api-security"))
    assert row.completion_state == "CI pending"
    assert row.pr_url == "https://github.com/acme-corp/example-project/pull/700"

    assert {:ok, monitor} =
             Fanout.monitor(result.run_path,
               ci_watch_status_fun: fn "ciw-test" ->
                 %{
                   watch_id: "ciw-test",
                   status: "passed",
                   repo: "acme-corp/example-project",
                   pr_number: 700
                 }
               end
             )

    assert %{derived_state: "ci_green"} =
             Enum.find(monitor.assignments, &(&1.assignment_id == "auth-api-security"))

    assert {:ok, status} = Fanout.status(result.run_path)
    row = Enum.find(status.assignments, &(&1.assignment_id == "auth-api-security"))
    assert row.completion_state == "CI green"
  end

  test "dynamic coverage plan balances low-coverage modules across hosts", %{root: root} do
    modules = [
      %{path: "lib/one/api/token.ex", coverage: 20.0, risk: "high"},
      %{path: "lib/one/reports/export.ex", coverage: 35.0, risk: "medium"},
      %{path: "lib/one/workers/sync.ex", coverage: 10.0, risk: "critical"},
      %{path: "lib/one/integrations/client.ex", coverage: 65.0, risk: "low"}
    ]

    assert {:ok, result} =
             Fanout.plan("coverage-dynamic",
               baseline: "53907e03",
               root: root,
               run_id: "coverage-dynamic-test",
               coverage_modules: modules,
               host_count: 2,
               host: ["h1=/repo,/worktrees,mise exec --", "h2=/repo,/worktrees,mise exec --"],
               risk_rules: %{"forbidden_paths" => ["lib/one_web/live/**"]}
             )

    assert result.assignment_count == 2
    assert result.assignment_ids == ["coverage-01", "coverage-02"]

    first = read_json!(Path.join([result.run_path, "assignments", "coverage-01.json"]))
    second = read_json!(Path.join([result.run_path, "assignments", "coverage-02.json"]))

    assert first["resolved_environment"]["host"] == "h1"
    assert second["resolved_environment"]["host"] == "h2"
    assert first["intent"]["scope"]["forbidden"] == ["lib/one_web/live/**"]
    assert Enum.any?(first["intent"]["scope"]["allowed"], &String.starts_with?(&1, "test/"))
    assert first["intent"]["task_objective"] =~ "Modules:"
  end

  test "dynamic coverage files risk rules and host defaults are normalized", %{root: root} do
    coverage_file = Path.join(root, "coverage.csv")

    File.write!(coverage_file, """
    # module,path,coverage,risk
    One.Api.Token, lib/one/api/token.ex, 44.5%, critical
    lib/one/reports/export.ex, 10, high
    lib/one/missing_coverage.ex, nope
    lib/one/plain.ex
    """)

    assert {:ok, result} =
             Fanout.plan("coverage-dynamic",
               baseline: "53907e03",
               root: root,
               run_id: "coverage-file-test",
               coverage_file: coverage_file,
               host_count: 4,
               host: ["solo"],
               risk_rules: "critical=100;high=40;ignored"
             )

    assert result.assignment_ids == ["coverage-01", "coverage-02", "coverage-03", "coverage-04"]

    hosts =
      Enum.map(result.assignment_ids, fn assignment_id ->
        read_json!(Path.join([result.run_path, "assignments", "#{assignment_id}.json"]))
        |> get_in(["resolved_environment", "host"])
      end)

    assert hosts == ["solo", "host-2", "host-3", "host-4"]

    first = read_json!(Path.join([result.run_path, "assignments", "coverage-01.json"]))
    assert first["intent"]["task_objective"] =~ "44.5%"

    risk_rules = Path.join(root, "risk-rules.json")
    File.write!(risk_rules, Jason.encode!(%{forbidden_paths: ["lib/one_web/**"]}))

    assert {:ok, mapped_host} =
             Fanout.plan("coverage-dynamic",
               baseline: "53907e03",
               root: root,
               run_id: "coverage-map-host",
               coverage_modules: [
                 %{name: "Token", source: "lib/one/api/token.ex", covered: 20},
                 "lib/one/string_module.ex",
                 123
               ],
               hosts: [%{name: "map-host", base_path: "/repo", worktree_root: "/tmp/work"}],
               risk_rules: risk_rules
             )

    mapped =
      read_json!(Path.join([mapped_host.run_path, "assignments", "coverage-01.json"]))

    assert mapped["resolved_environment"]["host"] == "map-host"
    assert mapped["resolved_environment"]["base_path"] == "/repo"
    assert mapped["intent"]["scope"]["forbidden"] == ["lib/one_web/**"]
  end

  test "stale or malformed reports are preserved as rejected evidence", %{root: root} do
    {:ok, result} =
      Fanout.plan("test-coverage",
        baseline: "53907e03",
        root: root,
        run_id: "test-coverage-reports"
      )

    assert {:error, "sequence_mismatch", %{status: :rejected, path: path, rejection: rejection}} =
             Fanout.accept_report(result.run_path, %{
               report_id: "2026-05-08T12-55-03Z-pr_opened",
               assignment_id: "auth-api-security",
               agent_id: "codex-s-test",
               sequence: 4,
               previous_report_id: nil,
               state: "pr_opened",
               reported_at: "2026-05-08T12:55:03Z",
               data: %{"pr_url" => "https://github.com/acme-corp/example-project/pull/596"}
             })

    assert File.exists?(path)
    assert rejection["reason"] == "sequence_mismatch"
    assert rejection["expected_sequence"] == 1
    assert rejection["received_sequence"] == 4
  end

  test "preflight handles excluded assignments fallback checks and launch error branches", %{
    root: root
  } do
    {:ok, result} =
      Fanout.plan("test-coverage",
        baseline: "53907e03",
        root: root,
        run_id: "test-coverage-edge-launch"
      )

    update_assignment!(result.run_path, "integrations-boundaries", fn assignment ->
      assignment |> Map.put("excluded", true) |> Map.put("state", "excluded")
    end)

    assert {:ok, preflight} =
             Fanout.preflight(result.run_path,
               runner: fn _assignment, _script -> {:ok, ""} end
             )

    assert preflight.result == "pass"

    assert %{publishability: "skipped"} =
             Enum.find(preflight.assignments, &(&1.assignment_id == "integrations-boundaries"))

    assert %{publishability: "pass", failed_checks: []} =
             Enum.find(preflight.assignments, &(&1.assignment_id == "auth-api-security"))

    one_arg_runner = fn script ->
      assert script =~ "launch_codex_goal.sh"

      {:ok,
       """
       JX_LAUNCH\tassignment_start_commit\t53907e03
       JX_LAUNCH\tagent_id\tcodex-one-arg
       JX_LAUNCH\tsession_name\tjx_fanout_one_arg
       """}
    end

    assert {:ok, launch} = Fanout.launch(result.run_path, runner: one_arg_runner)
    assert length(launch.assignments) == 4
    assert Enum.all?(launch.assignments, &(&1.agent_id == "codex-one-arg"))

    assert {:error, "unknown assignment \"missing\""} =
             Fanout.launch(result.run_path, "missing", runner: one_arg_runner)

    {:ok, mismatch_run} =
      Fanout.plan("test-coverage",
        baseline: "53907e03",
        root: root,
        run_id: "test-coverage-launch-mismatch"
      )

    assert {:ok, %{result: "pass"}} =
             Fanout.preflight(mismatch_run.run_path,
               runner: fn _assignment, _script -> {:ok, preflight_output()} end
             )

    assert {:error, {:launch_failed, [mismatch]}} =
             Fanout.launch(mismatch_run.run_path, "auth-api-security",
               runner: fn _assignment, _script ->
                 {:ok, "JX_LAUNCH\tassignment_start_commit\tbad-start\n"}
               end
             )

    assert mismatch.reason == "assignment_start_commit_mismatch"

    assert {:error, {:launch_failed, [failed]}} =
             Fanout.launch(mismatch_run.run_path, "liveview-ui",
               runner: fn _assignment, _script -> {:error, {:command_failed, 2, "boom"}} end
             )

    assert failed.reason == "launch_command_failed"
    assert failed.output == "boom"
  end

  test "ownership and PR creation cover warn-only validation and missing URL paths", %{
    root: root
  } do
    {:ok, result} =
      Fanout.plan("test-coverage",
        baseline: "53907e03",
        root: root,
        run_id: "test-coverage-pr-edges"
      )

    assert {:ok, warning_review} =
             Fanout.ownership_check(result.run_path, "auth-api-security",
               diff_paths: ["README.md", "lib/one_web/live/dashboard_live.ex"],
               warn_only: true
             )

    assert warning_review["status"] == "failed"
    assert warning_review["assignment_id"] == "auth-api-security"

    assert {:error, {:diff_failed, {:command_failed, 9, "diff failed"}}} =
             Fanout.ownership_check(result.run_path, "auth-api-security",
               runner: fn _assignment, _script ->
                 {:error, {:command_failed, 9, "diff failed"}}
               end
             )

    assert {:error, {:local_validation_required, "auth-api-security"}} =
             Fanout.open_pr(result.run_path, "auth-api-security",
               runner: fn _assignment, _script -> {:ok, ""} end
             )

    accept_local!(result.run_path, "auth-api-security")

    assert {:error, {:pr_create_failed, "missing PR URL"}} =
             Fanout.open_pr(result.run_path, "auth-api-security",
               runner: fn _assignment, script ->
                 if script =~ "diff --name-only",
                   do: {:ok, "test/one/api/token_test.exs\n"},
                   else: {:ok, ""}
               end
             )

    assert {:ok, pr} =
             Fanout.open_pr(result.run_path, "auth-api-security",
               allow_unvalidated: true,
               register_ci_watch: false,
               runner: fn _assignment, script ->
                 cond do
                   script =~ "diff --name-only" ->
                     {:ok, "test/one/api/token_test.exs\n"}

                   script =~ "gh pr create" ->
                     {:ok, "https://github.com/acme-corp/example-project/pull/701\n"}
                 end
               end
             )

    assert pr.state == "pr_opened"
    assert pr.ci_watch == nil
    assert pr.pr["repo"] == "acme-corp/example-project"
    assert pr.pr["number"] == 701
  end

  test "monitor maps CI watch statuses and report validation rejects unsafe history", %{
    root: root
  } do
    {:ok, result} =
      Fanout.plan("test-coverage",
        baseline: "53907e03",
        root: root,
        run_id: "test-coverage-monitor-reports"
      )

    watch_statuses = %{
      "auth-api-security" => "failed",
      "liveview-ui" => "cancelled",
      "oban-audit" => "superseded",
      "reports-export" => "active",
      "integrations-boundaries" => "mystery"
    }

    Enum.each(watch_statuses, fn {assignment_id, status} ->
      update_assignment!(result.run_path, assignment_id, fn assignment ->
        put_in(assignment, ["evidence", "ci_watch"], %{
          "watch_id" => "watch-#{assignment_id}",
          "status" => status,
          "repo" => "acme-corp/example-project",
          "pr_number" => 700
        })
      end)
    end)

    assert {:ok, monitor} =
             Fanout.monitor(result.run_path,
               ci_watch_status_fun: fn "watch-" <> assignment_id ->
                 %{
                   watch_id: "watch-#{assignment_id}",
                   status: Map.fetch!(watch_statuses, assignment_id),
                   repo: "acme-corp/example-project",
                   pr_number: 700
                 }
               end
             )

    states = Map.new(monitor.assignments, &{&1.assignment_id, &1.derived_state})
    assert states["auth-api-security"] == "ci_failed"
    assert states["liveview-ui"] == "ci_failed"
    assert states["oban-audit"] == "ci_failed"
    assert states["reports-export"] == "ci_pending"
    assert states["integrations-boundaries"] == "ci_pending"

    update_assignment!(result.run_path, "integrations-boundaries", fn assignment ->
      assignment |> Map.put("excluded", true) |> Map.put("state", "excluded")
    end)

    assert {:error, "report missing required fields: report_id" <> _} =
             Fanout.accept_report(result.run_path, %{
               assignment_id: "auth-api-security",
               agent_id: "codex-s-test",
               sequence: 1,
               state: "in_progress",
               reported_at: "2026-05-08T12:05:00Z"
             })

    assert {:error, "report sequence must be an integer"} =
             Fanout.accept_report(result.run_path, %{
               report_id: "bad-sequence",
               assignment_id: "auth-api-security",
               agent_id: "codex-s-test",
               sequence: "1",
               state: "in_progress",
               reported_at: "2026-05-08T12:05:00Z"
             })

    assert {:error, "invalid_state", %{rejection: invalid_state}} =
             Fanout.accept_report(result.run_path, %{
               report_id: "invalid-state",
               assignment_id: "auth-api-security",
               agent_id: "codex-s-test",
               sequence: 1,
               previous_report_id: nil,
               state: "nonsense",
               reported_at: "2026-05-08T12:05:00Z"
             })

    assert invalid_state["received_state"] == "nonsense"

    assert {:error, "assignment_excluded", %{rejection: excluded}} =
             Fanout.accept_report(result.run_path, %{
               report_id: "excluded-report",
               assignment_id: "integrations-boundaries",
               agent_id: "codex-s-test",
               sequence: 1,
               previous_report_id: nil,
               state: "in_progress",
               reported_at: "2026-05-08T12:05:00Z"
             })

    assert excluded["assignment_id"] == "integrations-boundaries"

    assert {:ok, %{status: :accepted}} =
             Fanout.accept_report(result.run_path, %{
               report_id: "accepted-1",
               assignment_id: "auth-api-security",
               agent_id: "codex-s-test",
               sequence: 1,
               previous_report_id: nil,
               state: "in_progress",
               reported_at: "2026-05-08T12:05:00Z"
             })

    assert {:error, "previous_report_mismatch", %{rejection: previous}} =
             Fanout.accept_report(result.run_path, %{
               report_id: "accepted-2",
               assignment_id: "auth-api-security",
               agent_id: "codex-s-test",
               sequence: 2,
               previous_report_id: "wrong",
               state: "blocked",
               reported_at: "2026-05-08T12:06:00Z"
             })

    assert previous["expected_previous_report_id"] == "accepted-1"

    assert {:error, "report_already_exists", %{rejection: duplicate}} =
             Fanout.accept_report(result.run_path, %{
               report_id: "accepted-1",
               assignment_id: "auth-api-security",
               agent_id: "codex-s-test",
               sequence: 2,
               previous_report_id: "accepted-1",
               state: "blocked",
               reported_at: "2026-05-08T12:07:00Z"
             })

    assert duplicate["original_report_id"] == "accepted-1"
  end

  test "plan rejects run ids that would escape the fanout root", %{root: root} do
    assert {:error, "run id contains path separators or dot segments"} =
             Fanout.plan("test-coverage",
               baseline: "53907e03",
               root: root,
               run_id: "../outside"
             )

    refute File.exists?(Path.expand(Path.join(root, "../outside")))
  end

  test "report ids and assignment ids cannot escape report directories", %{root: root} do
    {:ok, result} =
      Fanout.plan("test-coverage",
        baseline: "53907e03",
        root: root,
        run_id: "test-coverage-path-safety"
      )

    assert {:error, "report id contains path separators or dot segments"} =
             Fanout.accept_report(result.run_path, %{
               report_id: "../outside",
               assignment_id: "auth-api-security",
               agent_id: "codex-s-test",
               sequence: 1,
               previous_report_id: nil,
               state: "in_progress",
               reported_at: "2026-05-08T12:05:00Z"
             })

    assert {:error, "assignment id contains path separators or dot segments"} =
             Fanout.accept_report(result.run_path, %{
               report_id: "2026-05-08T12-05-00Z-in_progress",
               assignment_id: "../auth-api-security",
               agent_id: "codex-s-test",
               sequence: 1,
               previous_report_id: nil,
               state: "in_progress",
               reported_at: "2026-05-08T12:05:00Z"
             })

    refute File.exists?(Path.join(result.run_path, "reports/outside.json"))
    assert {:ok, status} = Fanout.status(result.run_path)
    assert status.counts["planned"] == 5
  end

  defp read_json!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp write_json!(path, payload) do
    File.write!(path, Jason.encode!(payload, pretty: true))
  end

  defp update_assignment!(run_path, assignment_id, fun) do
    path = Path.join([run_path, "assignments", "#{assignment_id}.json"])
    assignment = read_json!(path)
    updated = fun.(assignment)
    write_json!(path, updated)
    updated
  end

  defp accept_local!(run_path, assignment_id) do
    assert {:ok, %{status: :accepted}} =
             Fanout.accept_report(run_path, %{
               report_id: "#{assignment_id}-local-validated",
               assignment_id: assignment_id,
               agent_id: "codex-s-test",
               sequence: 1,
               previous_report_id: nil,
               state: "local_validated",
               reported_at: "2026-05-08T12:05:00Z",
               data: %{"validation" => "passed"}
             })
  end

  defp preflight_output(failing_check \\ nil) do
    [
      "clean_repo",
      "expected_head",
      "fresh_worktree",
      "assigned_branch",
      "validation_prefix_known",
      "mix_version_passes",
      "hook_health_passes",
      "github_auth_passes",
      "dry_run_push_passes"
    ]
    |> Enum.map(fn check ->
      status = if check == failing_check, do: "fail", else: "pass"
      "JX_CHECK\t#{check}\t#{status}\t#{check} #{status}"
    end)
    |> Enum.join("\n")
  end
end
