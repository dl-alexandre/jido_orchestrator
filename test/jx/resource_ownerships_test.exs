defmodule JX.ResourceOwnershipsTest do
  use ExUnit.Case, async: false

  alias JX.Repo
  alias JX.ResourceOwnerships
  alias JX.ResourceOwnerships.Resource

  setup do
    Repo.delete_all(Resource)
    :ok
  end

  test "register_tmux_session records ownership and dry-run emits non-destructive cleanup evidence" do
    now = ~U[2026-05-12 10:00:00Z]

    assert {:ok, resource} =
             ResourceOwnerships.register_tmux_session(
               %{
                 owner_project: "dev_ide",
                 assignment_id: "asgn-1",
                 execution_id: "exec-1",
                 resource_name: "devide_exec_1",
                 tmux_server: "jx",
                 reason: "fleet execution tmux session"
               },
               now: now
             )

    assert resource.cleanup_policy == "kill_tmux_session"

    assert {:ok, report} =
             ResourceOwnerships.cleanup_dry_run(now: DateTime.add(now, 10, :second))

    assert report.apply_available == false

    assert [
             %{
               owner_project: "dev_ide",
               assignment_id: "asgn-1",
               execution_id: "exec-1",
               resource_type: "tmux_session",
               resource: "jx/devide_exec_1",
               state: "missing",
               live_status: "missing",
               attached: false,
               why_owned: why,
               cleanup_command: command
             }
           ] = report.resources

    assert why =~ "registered owner_project=dev_ide"
    assert why =~ "assignment=asgn-1"
    assert why =~ "execution=exec-1"
    assert command == "tmux -L 'jx' -f /dev/null kill-session -t 'devide_exec_1'"
  end

  test "temp paths are attributable and expose rm command only in dry-run" do
    tmp = Path.join(System.tmp_dir!(), "jx-resource-ownership-test")

    assert {:ok, _resource} =
             ResourceOwnerships.register_temp_path(%{
               owner_project: "saysure",
               execution_id: "task-1",
               resource_type: "worktree_path",
               resource_name: "task-1",
               resource_path: tmp,
               reason: "test worktree"
             })

    assert {:ok, %{resources: [item]}} = ResourceOwnerships.cleanup_dry_run()

    assert item.resource == tmp
    assert item.live_status == "missing"
    assert item.cleanup_command == "rm -rf '#{tmp}'"
    refute File.exists?(tmp)
  end

  test "cleanup ignores unregistered temp paths and tmux sessions" do
    tmp = Path.join(System.tmp_dir!(), "jx-unregistered-resource-test")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    tmux_session = "jx_unregistered_#{System.unique_integer([:positive])}"
    tmux_server = "jx-test-#{System.unique_integer([:positive])}"

    tmux_started? =
      if System.find_executable("tmux") do
        case System.cmd("tmux", [
               "-L",
               tmux_server,
               "-f",
               "/dev/null",
               "new-session",
               "-d",
               "-s",
               tmux_session,
               "sh"
             ]) do
          {_output, 0} -> true
          _error -> false
        end
      else
        false
      end

    on_exit(fn ->
      if tmux_started? do
        System.cmd(
          "tmux",
          ["-L", tmux_server, "-f", "/dev/null", "kill-session", "-t", tmux_session],
          stderr_to_stdout: true
        )
      end
    end)

    assert {:ok, %{resources: []}} = ResourceOwnerships.cleanup_dry_run()
  end

  test "re-registration preserves original created_at" do
    original = ~U[2026-05-12 10:00:00Z]
    later = ~U[2026-05-13 10:00:00Z]

    attrs = %{
      owner_project: "dev_ide",
      assignment_id: "asgn-1",
      execution_id: "exec-1",
      resource_name: "devide_exec_1",
      tmux_server: "jx",
      reason: "first registration"
    }

    assert {:ok, first} = ResourceOwnerships.register_tmux_session(attrs, now: original)

    assert {:ok, second} =
             ResourceOwnerships.register_tmux_session(
               %{attrs | reason: "second registration"},
               now: later
             )

    assert first.resource_id == second.resource_id
    stored = Repo.get_by!(Resource, resource_id: first.resource_id)
    assert DateTime.compare(stored.created_at, original) == :eq
    assert stored.reason == "second registration"
  end

  test "apply path is explicitly guarded" do
    assert {:error, :cleanup_apply_not_implemented} = ResourceOwnerships.cleanup_apply()
  end

  test "ownership audit lists registered resources and searchable exemptions" do
    assert {:ok, _resource} =
             ResourceOwnerships.register_tmux_session(%{
               owner_type: "orchestrator_daemon",
               owner_project: "orchestrator",
               resource_name: "jx-orchestrator",
               tmux_server: "jx",
               reason: "orchestrator daemon tmux session"
             })

    assert {:ok, audit} = ResourceOwnerships.ownership_audit()

    assert [
             %{
               owner_type: "orchestrator_daemon",
               resource_type: "tmux_session",
               resource: "jx/jx-orchestrator"
             }
           ] = audit.registered_long_lived

    assert Enum.any?(
             audit.exempt_creator_paths,
             &(&1.creator == "JX.HostDoctor.tmux_checks/1" and
                 &1.cleanup_policy == "self_cleaning_probe")
           )

    assert Enum.any?(
             audit.exempt_creator_paths,
             &(&1.creator == "JX.PaneTransport.probe/2" and
                 &1.cleanup_policy == "no_resource_created")
           )

    assert audit.unknown_unclassified == []
  end

  test "creation paths can mark resources exempt with evidence" do
    assert {:ok, resource} =
             ResourceOwnerships.mark_exempt(%{
               owner_project: "dev_ide",
               resource_type: "tmux_session",
               resource_name: "operator-attached-session",
               cleanup_policy: "manual",
               reason: "operator-owned attached tmux session"
             })

    assert resource.state == "exempt"
    assert resource.cleanup_policy == "exempt"
  end
end
