defmodule JX.FanoutDogfood.FakeSSH do
  @moduledoc false

  @behaviour JX.SSH

  @impl true
  def run(_host, script, _opts \\ []) do
    scripts = Process.get(:dogfood_ssh_scripts, [])
    Process.put(:dogfood_ssh_scripts, [script | scripts])

    cond do
      String.contains?(script, "echo running") ->
        {:ok, "running\n1700000000\nnone\n"}

      String.contains?(script, "goal_status.json") ->
        {:ok, ~s({"status":"requested","requested_at":"2026-05-10T00:00:00Z"})}

      true ->
        {:ok, "ready\n"}
    end
  end

  @impl true
  def attach(_host, _session_name, _opts \\ []), do: :ok

  @impl true
  def stream_log(_host, _log_path, _opts \\ []), do: :ok
end

defmodule JX.FanoutDogfood do
  @moduledoc false

  alias JX.CiWatches.CiWatch
  alias JX.Fanout
  alias JX.Migrations
  alias JX.Repo
  alias JX.Workspace

  def run do
    db_path =
      Path.join(System.tmp_dir!(), "jx-fanout-dogfood-#{System.unique_integer([:positive])}.db")

    root =
      Path.join(System.tmp_dir!(), "jx-fanout-dogfood-runs-#{System.unique_integer([:positive])}")

    restart_with_temp_db(db_path)

    try do
      stale_baseline_blocks_preflight(root)
      hook_auth_push_blocks_preflight(root)
      ownership_violation_blocks_pr(root)
      pr_registers_watch_and_monitor_transitions(root)
      goal_evidence_surfaces_in_status()

      IO.puts("fanout dogfood passed")
      IO.puts("root: #{root}")
    after
      File.rm_rf(root)

      for suffix <- ["", "-shm", "-wal", "-journal"] do
        File.rm(db_path <> suffix)
      end
    end
  end

  defp restart_with_temp_db(db_path) do
    Application.stop(:jx)

    repo_config =
      :jx
      |> Application.get_env(JX.Repo, [])
      |> Keyword.put(:database, db_path)
      |> Keyword.put(:pool_size, 1)

    Application.put_env(:jx, JX.Repo, repo_config)
    Application.put_env(:jx, :ssh_adapter, JX.FanoutDogfood.FakeSSH)

    {:ok, _apps} = Application.ensure_all_started(:jx)
    :ok = Migrations.migrate_started(log: false)
  end

  defp stale_baseline_blocks_preflight(root) do
    result = plan!(root, "dogfood-stale-baseline")

    {:ok, preflight} =
      Fanout.preflight(result.run_path,
        runner: fn _assignment, _script ->
          {:error, {:command_failed, 1, preflight_output(["expected_head"])}}
        end
      )

    assert!(preflight.result == "fail", "stale baseline should fail preflight")

    assert_failed_checks!(
      preflight,
      "coverage-01",
      ["expected_head"],
      "stale baseline should report expected_head"
    )

    assert!(
      match?(
        {:error, {:preflight_required, ["coverage-01"]}},
        Fanout.launch(result.run_path, :all)
      ),
      "stale baseline should block launch"
    )
  end

  defp hook_auth_push_blocks_preflight(root) do
    result = plan!(root, "dogfood-hook-auth-push")
    failed = ["hook_health_passes", "github_auth_passes", "dry_run_push_passes"]

    {:ok, preflight} =
      Fanout.preflight(result.run_path,
        runner: fn _assignment, _script ->
          {:error, {:command_failed, 1, preflight_output(failed)}}
        end
      )

    assert!(preflight.result == "fail", "hook/auth/push failures should fail preflight")

    assert_failed_checks!(
      preflight,
      "coverage-01",
      failed,
      "preflight should report hook/auth/push"
    )

    assert!(
      match?(
        {:error, {:preflight_required, ["coverage-01"]}},
        Fanout.launch(result.run_path, :all)
      ),
      "hook/auth/push failures should block launch"
    )
  end

  defp ownership_violation_blocks_pr(root) do
    result = plan!(root, "dogfood-ownership")
    accept_local_validated!(result.run_path)

    runner = fn _assignment, script ->
      cond do
        String.contains?(script, "diff --name-only") ->
          {:ok, "README.md\nlib/one_web/live/dashboard_live.ex\n"}

        String.contains?(script, "gh pr create") ->
          raise "PR creation should not run after ownership violation"
      end
    end

    assert!(
      match?(
        {:error, {:ownership_failed, %{"outside_write_paths" => ["README.md"]}}},
        Fanout.open_pr(result.run_path, "coverage-01", runner: runner, allow_unvalidated: false)
      ),
      "ownership violations should block PR creation"
    )
  end

  defp pr_registers_watch_and_monitor_transitions(root) do
    result = plan!(root, "dogfood-pr-watch")
    accept_local_validated!(result.run_path)

    runner = fn _assignment, script ->
      cond do
        String.contains?(script, "diff --name-only") ->
          {:ok, "lib/one/api/token.ex\ntest/one/api/token_test.exs\n"}

        String.contains?(script, "gh pr create") ->
          {:ok,
           """
           JX_PR\turl\thttps://github.com/acme-corp/example-project/pull/701
           JX_PR\thead_sha\tabc701
           """}
      end
    end

    {:ok, pr} =
      Fanout.open_pr(result.run_path, "coverage-01",
        runner: runner,
        repo: "acme-corp/example-project"
      )

    assert!(pr.state == "ci_pending", "PR creation should move assignment to CI pending")
    assert!(pr.ci_watch["watch_id"] != nil, "PR creation should register CI watch")
    assert!(Repo.get_by(CiWatch, pr_number: 701) != nil, "CI watch should be durable")

    assert_monitor_state!(result.run_path, "active", "ci_pending", "CI pending")
    assert_monitor_state!(result.run_path, "passed", "ci_green", "CI green")
    assert_monitor_state!(result.run_path, "failed", "ci_failed", "CI failed")
  end

  defp goal_evidence_surfaces_in_status do
    {:ok, _host} =
      Workspace.add_host(%{
        name: "dogfood-host",
        ssh_target: "dogfood@example.test",
        workspace_path: "/tmp/jx-dogfood-agent"
      })

    {:ok, _project} =
      Workspace.add_project(%{
        name: "dogfood",
        host_name: "dogfood-host",
        repo_path: "/tmp/jx-dogfood-repo"
      })

    {:ok, _task} =
      Workspace.assign_task("dogfood", "verify Codex goal evidence",
        agent_name: "codex",
        goal: true
      )

    Process.put(:dogfood_ssh_scripts, [])

    [status] = Workspace.list_statuses()

    assert!(
      get_in(status, [:goal_status, "status"]) == "requested",
      "jx status path should include goal status evidence"
    )

    status_scripts = Process.get(:dogfood_ssh_scripts, [])

    assert!(
      Enum.any?(status_scripts, &String.contains?(&1, "goal_status.json")),
      "status should read goal_status.json"
    )

    refute!(
      Enum.any?(status_scripts, &String.contains?(&1, "capture-pane")),
      "status should not require pane inspection for goal evidence"
    )
  end

  defp plan!(root, run_id) do
    {:ok, result} =
      Fanout.plan("coverage-dynamic",
        baseline: "base123",
        root: root,
        run_id: run_id,
        coverage_modules: [
          %{path: "lib/one/api/token.ex", coverage: 20.0, risk: "low"}
        ],
        host_count: 1,
        host: ["dogfood-host=/tmp/jx-dogfood-repo,/tmp/jx-dogfood-worktrees,mix"],
        risk_rules: %{"forbidden_paths" => ["lib/one_web/live/**"]}
      )

    result
  end

  defp accept_local_validated!(run_path) do
    {:ok, %{status: :accepted}} =
      Fanout.accept_report(run_path, %{
        report_id: "2026-05-10T00-00-00Z-local",
        assignment_id: "coverage-01",
        agent_id: "codex-dogfood",
        sequence: 1,
        previous_report_id: nil,
        state: "local_validated",
        reported_at: "2026-05-10T00:00:00Z",
        data: %{"validation" => "passed"}
      })
  end

  defp assert_monitor_state!(run_path, ci_status, derived_state, completion_state) do
    {:ok, monitor} =
      Fanout.monitor(run_path,
        ci_watch_status_fun: fn _watch_id ->
          %{
            watch_id: "ciw-dogfood",
            status: ci_status,
            repo: "acme-corp/example-project",
            pr_number: 701
          }
        end
      )

    row = Enum.find(monitor.assignments, &(&1.assignment_id == "coverage-01"))
    assert!(row.derived_state == derived_state, "monitor should move to #{derived_state}")
    assert!(row.completion_state == completion_state, "status should show #{completion_state}")
  end

  defp assert_failed_checks!(preflight, assignment_id, expected, message) do
    assignment = Enum.find(preflight.assignments, &(&1.assignment_id == assignment_id))
    assert!(Enum.sort(assignment.failed_checks) == Enum.sort(expected), message)
  end

  defp preflight_output(failing_checks) do
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
      status = if check in failing_checks, do: "fail", else: "pass"
      "JX_CHECK\t#{check}\t#{status}\t#{check} #{status}"
    end)
    |> Enum.join("\n")
  end

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise("dogfood assertion failed: #{message}")

  defp refute!(false, _message), do: :ok
  defp refute!(true, message), do: raise("dogfood assertion failed: #{message}")
end

JX.FanoutDogfood.run()
