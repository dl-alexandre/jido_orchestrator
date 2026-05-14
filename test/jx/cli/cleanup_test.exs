defmodule JX.CLI.CleanupTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JX.CLI.Cleanup
  alias JX.Repo
  alias JX.ResourceOwnerships
  alias JX.ResourceOwnerships.Resource

  defmodule FakeWorkspace do
    def ownership_audit(opts) do
      send(self(), {:ownership_audit, opts})

      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         registered_long_lived: [
           %{
             resource: "jx/devide_exec_1",
             owner_type: "project",
             owner_project: "dev_ide",
             resource_type: "tmux_session",
             state: "active",
             reason: "fleet execution tmux session"
           }
         ],
         exempt_creator_paths: [
           %{
             creator: "JX.HostDoctor.tmux_checks/1",
             resource_type: "tmux_session",
             cleanup_policy: "self_cleaning_probe",
             reason: "short-lived probe"
           }
         ],
         unknown_unclassified: ["orphan-1"],
         unknown_detection: "not_detectable"
       }}
    end

    def cleanup_dry_run(opts) do
      send(self(), {:cleanup_dry_run, opts})

      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         apply_available: true,
         resources: [
           %{
             resource: "jx/devide_exec_1",
             why_owned: "registered owner_project=dev_ide assignment=asgn-1 execution=exec-1",
             state: "live",
             live_status: "attached",
             attached: true,
             cleanup_command: "tmux -L 'jx' -f /dev/null kill-session -t 'devide_exec_1'"
           },
           %{
             resource: "tmp/orphan",
             why_owned: "orphan",
             state: "unknown",
             live_status: "unknown",
             attached: nil,
             cleanup_command: "rm -rf tmp/orphan"
           },
           %{
             resource: "tmp/detached",
             why_owned: "orphan",
             state: "stale",
             live_status: "detached",
             attached: false,
             cleanup_command: "rm -rf tmp/detached"
           }
         ]
       }}
    end

    def cleanup_apply(opts) do
      send(self(), {:cleanup_apply, opts})
      {:error, :cleanup_apply_not_implemented}
    end
  end

  defmodule FakeWorkspaceUnavailable do
    def cleanup_dry_run(opts) do
      send(self(), {:cleanup_dry_run_unavailable, opts})

      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         apply_available: false,
         resources: []
       }}
    end

    def ownership_audit(opts) do
      FakeWorkspace.ownership_audit(opts)
    end

    def cleanup_apply(opts) do
      FakeWorkspace.cleanup_apply(opts)
    end
  end

  setup do
    Repo.delete_all(Resource)

    {:ok, _resource} =
      ResourceOwnerships.register_tmux_session(%{
        owner_project: "dev_ide",
        assignment_id: "asgn-1",
        execution_id: "exec-1",
        resource_name: "devide_exec_1",
        tmux_server: "jx",
        reason: "fleet execution tmux session"
      })

    :ok
  end

  test "usage_lines returns usage string" do
    assert Cleanup.usage_lines() == [
             "jx cleanup --dry-run|audit [--owner-project <name>] [--type tmux_session|temp_path|worktree_path|task_dir|log_path] [--json]"
           ]
  end

  test "dry-run prints attributable resources and exact cleanup command" do
    output =
      capture_io(fn ->
        assert :ok = Cleanup.run(["--dry-run"], start_app: fn -> :ok end)
      end)

    assert output =~ "jx/devide_exec_1"
    assert output =~ "registered owner_project=dev_ide assignment=asgn-1 execution=exec-1"
    assert output =~ "tmux -L 'jx' -f /dev/null kill-session -t 'devide_exec_1'"
    assert output =~ "--apply is intentionally disabled"
  end

  test "dry-run JSON exposes stable resource fields" do
    output =
      capture_io(fn ->
        assert :ok = Cleanup.run(["--dry-run", "--json"], start_app: fn -> :ok end)
      end)

    assert %{
             "apply_available" => false,
             "resources" => [
               %{
                 "assignment_id" => "asgn-1",
                 "cleanup_command" => "tmux -L 'jx' -f /dev/null kill-session -t 'devide_exec_1'",
                 "execution_id" => "exec-1",
                 "owner_project" => "dev_ide",
                 "resource" => "jx/devide_exec_1",
                 "resource_type" => "tmux_session",
                 "why_owned" =>
                   "registered owner_project=dev_ide assignment=asgn-1 execution=exec-1"
               }
             ]
           } = Jason.decode!(output)
  end

  test "apply is parsed but guarded" do
    assert {:error, :cleanup_apply_not_implemented} =
             Cleanup.run(["--apply"], start_app: fn -> :ok end)
  end

  test "audit renders registered resources and exemptions as JSON" do
    output =
      capture_io(fn ->
        assert :ok = Cleanup.run(["audit", "--json"], start_app: fn -> :ok end)
      end)

    assert %{
             "registered_long_lived" => [
               %{
                 "owner_project" => "dev_ide",
                 "owner_type" => "project",
                 "resource" => "jx/devide_exec_1",
                 "resource_type" => "tmux_session"
               }
             ],
             "exempt_creator_paths" => exemptions,
             "unknown_unclassified" => []
           } = Jason.decode!(output)

    assert Enum.any?(exemptions, &(&1["creator"] == "JX.HostDoctor.tmux_checks/1"))
  end

  test "audit renders text output with tables and unknown count" do
    output =
      capture_io(fn ->
        assert :ok =
                 Cleanup.run(["audit"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:ownership_audit, opts}
    assert opts[:owner_project] == nil
    assert opts[:resource_type] == nil

    assert output =~ "registered long-lived resources"
    assert output =~ "jx/devide_exec_1"
    assert output =~ "project:dev_ide"
    assert output =~ "tmux_session"
    assert output =~ "active"
    assert output =~ "fleet execution tmux session"
    assert output =~ "known exempt creator paths"
    assert output =~ "JX.HostDoctor.tmux_checks/1"
    assert output =~ "self_cleaning_probe"
    assert output =~ "unknown/unclassified: 1"
  end

  test "audit passes owner-project and type filters to workspace" do
    capture_io(fn ->
      assert :ok =
               Cleanup.run(
                 ["audit", "--owner-project", "dev_ide", "--type", "tmux_session"],
                 start_app: start_app_callback(),
                 workspace: FakeWorkspace
               )
    end)

    assert_received :started
    assert_received {:ownership_audit, opts}
    assert opts[:owner_project] == "dev_ide"
    assert opts[:resource_type] == "tmux_session"
  end

  test "dry-run renders text when apply is available" do
    output =
      capture_io(fn ->
        assert :ok =
                 Cleanup.run(["--dry-run"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:cleanup_dry_run, opts}
    assert opts[:owner_project] == nil
    assert opts[:resource_type] == nil

    assert output =~ "jx/devide_exec_1"
    assert output =~ "yes"
    assert output =~ "unknown"
    assert output =~ "no"
    assert output =~ "tmux -L 'jx' -f /dev/null kill-session -t 'devide_exec_1'"
    refute output =~ "--apply is intentionally disabled"
  end

  test "dry-run renders text when apply is not available" do
    output =
      capture_io(fn ->
        assert :ok =
                 Cleanup.run(["--dry-run"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspaceUnavailable
                 )
      end)

    assert_received :started
    assert_received {:cleanup_dry_run_unavailable, _opts}
    assert output =~ "--apply is intentionally disabled"
  end

  test "dry-run passes owner-project and type filters to workspace" do
    capture_io(fn ->
      assert :ok =
               Cleanup.run(
                 ["--dry-run", "--owner-project", "dev_ide", "--type", "tmux_session"],
                 start_app: start_app_callback(),
                 workspace: FakeWorkspace
               )
    end)

    assert_received :started
    assert_received {:cleanup_dry_run, opts}
    assert opts[:owner_project] == "dev_ide"
    assert opts[:resource_type] == "tmux_session"
  end

  test "apply routes through workspace and returns error" do
    assert {:error, :cleanup_apply_not_implemented} =
             Cleanup.run(["--apply"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert_received :started
    assert_received {:cleanup_apply, opts}
    assert opts[:owner_project] == nil
    assert opts[:resource_type] == nil
  end

  test "run rejects both --dry-run and --apply" do
    assert {:error, "choose either --dry-run or --apply"} =
             Cleanup.run(["--dry-run", "--apply"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    refute_received :started
    refute_received {:cleanup_dry_run, _}
    refute_received {:cleanup_apply, _}
  end

  test "run rejects missing mode" do
    assert {:error, message} =
             Cleanup.run([],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage:"
    refute_received :started
  end

  test "run rejects invalid options" do
    assert {:error, message} =
             Cleanup.run(["--dry-run", "--bad-opt"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "invalid options"
    refute_received :started
    refute_received {:cleanup_dry_run, _}
  end

  test "run rejects extra args" do
    assert {:error, message} =
             Cleanup.run(["--dry-run", "extra-arg"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage:"
    refute_received :started
    refute_received {:cleanup_dry_run, _}
  end

  test "audit rejects invalid options" do
    assert {:error, message} =
             Cleanup.run(["audit", "--bad-opt"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "invalid options"
    refute_received :started
    refute_received {:ownership_audit, _}
  end

  test "audit rejects extra args" do
    assert {:error, message} =
             Cleanup.run(["audit", "extra-arg"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage:"
    refute_received :started
    refute_received {:ownership_audit, _}
  end

  test "audit JSON routes through workspace" do
    output =
      capture_io(fn ->
        assert :ok =
                 Cleanup.run(["audit", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:ownership_audit, _opts}

    decoded = Jason.decode!(output)
    assert decoded["registered_long_lived"] != []
    assert decoded["exempt_creator_paths"] != []
    assert decoded["unknown_unclassified"] == ["orphan-1"]
  end

  test "dry-run JSON routes through workspace" do
    output =
      capture_io(fn ->
        assert :ok =
                 Cleanup.run(["--dry-run", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:cleanup_dry_run, _opts}

    decoded = Jason.decode!(output)
    assert decoded["apply_available"] == true
    assert length(decoded["resources"]) == 3

    resources = decoded["resources"]
    assert Enum.any?(resources, &(&1["attached"] == true))
    assert Enum.any?(resources, &(&1["attached"] == nil))
    assert Enum.any?(resources, &(&1["attached"] == false))
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
