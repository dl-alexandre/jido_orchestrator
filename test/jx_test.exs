defmodule JXTest do
  use ExUnit.Case

  describe "JX.Repo.init/2" do
    test "returns config unchanged when database is nil" do
      config = [database: nil, other: "value"]
      assert JX.Repo.init(:runtime, config) == {:ok, config}
    end

    test "returns config unchanged when database is :memory:" do
      config = [database: ":memory:", other: "value"]
      assert JX.Repo.init(:runtime, config) == {:ok, config}
    end

    test "creates parent directory when database path does not exist" do
      dir = Path.join(System.tmp_dir!(), "jx_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      db_path = Path.join(dir, "test.db")
      config = [database: db_path, other: "value"]
      assert JX.Repo.init(:runtime, config) == {:ok, config}
      assert File.dir?(dir)
    end

    test "succeeds when parent directory already exists" do
      dir = Path.join(System.tmp_dir!(), "jx_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      db_path = Path.join(dir, "test.db")
      config = [database: db_path, other: "value"]
      assert JX.Repo.init(:runtime, config) == {:ok, config}
    end
  end

  describe "JX public API – read-only delegations" do
    test "list functions return expected shapes" do
      assert is_list(JX.list_statuses())
      assert is_list(JX.list_delegations())
      assert is_list(JX.list_approvals())
      assert is_list(JX.list_ci_watches())
      assert is_list(JX.list_session_controls())
      assert is_list(JX.list_call_handoffs())
      assert is_list(JX.list_operation_executions())
      assert is_list(JX.list_session_observations())
      assert is_list(JX.list_session_changes())
      assert is_list(JX.list_stale_session_observations())
      assert is_list(JX.list_remote_session_observations())
    end

    test "google meet list functions return lists" do
      assert is_list(JX.google_meet_auth_profiles())
      assert is_list(JX.google_meet_sessions())
    end

    test "participant_plugins/0 returns a list" do
      assert is_list(JX.participant_plugins())
    end

    test "operator_profile/0 returns a map" do
      assert is_map(JX.operator_profile())
    end

    test "doctor_hosts/0 returns a report tuple" do
      assert {:ok, %{reports: reports}} = JX.doctor_hosts()
      assert is_list(reports)
    end

    test "project_gate/1 returns blocked report for nonexistent project" do
      assert {:ok, %{project: "nonexistent", eligible: false, status: "blocked"}} =
               JX.project_gate("nonexistent")
    end

    test "repo_doctor/1 returns error for nonexistent project" do
      assert JX.repo_doctor("nonexistent") == {:error, :project_not_found}
    end

    test "repo_gate/1 returns error for nonexistent project" do
      assert JX.repo_gate("nonexistent") == {:error, :project_not_found}
    end

    test "doctor_host/1 returns error for nonexistent host" do
      assert JX.doctor_host("nonexistent") == {:error, :host_not_found}
    end

    test "promotion_preflight/3 returns blocked report for nonexistent project" do
      assert {:ok, %{project: "nonexistent", eligible: false}} =
               JX.promotion_preflight("nonexistent", "source", "target")
    end

    test "promotion_run/3 returns blocked report for nonexistent project" do
      assert {:ok, %{project: "nonexistent", status: "blocked"}} =
               JX.promotion_run("nonexistent", "source", "target")
    end

    test "assign_task/2 returns error for nonexistent project" do
      assert JX.assign_task("nonexistent", "prompt") == {:error, :project_not_found}
    end
  end

  describe "JX public API – delegation edge cases" do
    test "delegation functions return not_found for nonexistent ids" do
      assert JX.cancel_delegation("nonexistent") == {:error, :delegation_not_found}
      assert JX.block_delegation("nonexistent", "summary") == {:error, :delegation_not_found}
      assert JX.fail_delegation("nonexistent", "summary") == {:error, :delegation_not_found}
      assert JX.complete_delegation("nonexistent") == {:error, :delegation_not_found}
      assert JX.start_delegation("nonexistent") == {:error, :delegation_not_found}
      assert JX.add_delegation_evidence("nonexistent", %{}) == {:error, :delegation_not_found}
      assert JX.delegation_brief("nonexistent") == {:error, :delegation_not_found}
      assert JX.delegation_preflight("nonexistent") == {:error, :delegation_not_found}
      assert JX.delegation_review("nonexistent") == {:error, :delegation_not_found}

      assert JX.decide_delegation_review("nonexistent", "accept") ==
               {:error, :delegation_not_found}
    end

    test "delegation list and summary functions return expected shapes" do
      assert is_list(JX.delegation_reviews())
      assert is_map(JX.delegation_timing())
    end
  end

  describe "JX public API – approval edge cases" do
    test "approval functions return not_found for nonexistent ids" do
      assert JX.get_approval("nonexistent") == nil
      assert JX.approval_detail("nonexistent") == {:error, :approval_not_found}
      assert JX.acknowledge_approval("nonexistent") == {:error, :approval_not_found}
      assert JX.dismiss_approval("nonexistent") == {:error, :approval_not_found}
    end

    test "approval_summary/0 returns a map" do
      assert is_map(JX.approval_summary())
    end
  end

  describe "JX public API – call handoff edge cases" do
    test "call handoff functions return not_found for nonexistent ids" do
      assert JX.close_call_handoff("nonexistent") == {:error, :call_handoff_not_found}
      assert JX.apply_call_handoff("nonexistent") == {:error, :call_handoff_not_found}
    end
  end

  describe "JX public API – ci watch edge cases" do
    test "ci watch functions return not_found for nonexistent ids" do
      assert JX.cancel_ci_watch("nonexistent", "summary") == {:error, :ci_watch_not_found}
      assert JX.review_ci_watch("nonexistent") == {:error, :ci_watch_not_found}
    end
  end

  describe "JX public API – google meet edge cases" do
    test "google meet session functions return not_found for nonexistent sessions" do
      assert JX.google_meet_session("nonexistent") == {:error, :google_meet_session_not_found}
      assert JX.google_meet_join_plan("nonexistent") == {:error, :google_meet_session_not_found}

      assert JX.google_meet_join_session("nonexistent") ==
               {:error, :google_meet_session_not_found}

      assert JX.google_meet_realtime_plan("nonexistent") ==
               {:error, :google_meet_session_not_found}

      assert JX.google_meet_start_realtime("nonexistent") ==
               {:error, :google_meet_session_not_found}

      assert JX.google_meet_realtime_consult("nonexistent", %{}) ==
               {:error, :google_meet_session_not_found}

      assert JX.google_meet_realtime_watch("nonexistent") ==
               {:error, :google_meet_session_not_found}

      assert JX.google_meet_sync_artifacts("nonexistent") ==
               {:error, :google_meet_session_not_found}

      assert JX.google_meet_export_session("nonexistent") ==
               {:error, :google_meet_session_not_found}
    end

    test "google meet auth functions return not_found for nonexistent profiles" do
      assert JX.google_meet_auth_url("nonexistent") ==
               {:error, :google_meet_auth_profile_not_found}

      assert JX.google_meet_exchange_auth_code("nonexistent", "code") ==
               {:error, :google_meet_auth_profile_not_found}
    end

    test "google_meet_create_session/1 returns error for empty attrs" do
      assert JX.google_meet_create_session(%{}) ==
               {:error, "Google Meet session requires --meeting <url-or-code>"}
    end
  end

  describe "JX public API – session control edge cases" do
    test "clear_session_control/1 returns not_found for nonexistent ref" do
      assert JX.clear_session_control("nonexistent") == {:error, :session_control_not_found}
    end
  end

  describe "JX public API – task edge cases" do
    test "attach, logs, and stop return not_found for nonexistent task ids" do
      assert JX.attach("nonexistent") == {:error, :task_not_found}
      assert JX.logs("nonexistent") == {:error, :task_not_found}
      assert JX.stop("nonexistent") == {:error, :task_not_found}
    end
  end
end
