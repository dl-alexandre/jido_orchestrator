defmodule JX.CLI.CleanupTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JX.CLI.Cleanup
  alias JX.Repo
  alias JX.ResourceOwnerships
  alias JX.ResourceOwnerships.Resource

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
end
