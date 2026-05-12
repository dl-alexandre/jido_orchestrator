defmodule JX.CLI.ApprovalsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Approvals

  defmodule FakeWorkspace do
    def list_approvals(opts) do
      send(self(), {:list_approvals, opts})
      [approval()]
    end

    def approval_detail(approval_id) do
      send(self(), {:approval_detail, approval_id})

      {:ok,
       %{
         approval: approval(approval_id),
         evidence: evidence(),
         recommendation: %{
           primary: "Propose acknowledgment",
           actions: ["Claim approval", "Propose action"]
         }
       }}
    end

    def acknowledge_approval(approval_id) do
      send(self(), {:acknowledge_approval, approval_id})
      {:ok, approval(approval_id, "acknowledged")}
    end

    def dismiss_approval(approval_id) do
      send(self(), {:dismiss_approval, approval_id})
      {:ok, approval(approval_id, "dismissed")}
    end

    defp approval(approval_id \\ "apr-1", status \\ "open") do
      %{
        approval_id: approval_id,
        source: "devide",
        workspace_id: "workspace-1",
        kind: "failed_run",
        severity: "warning",
        target_ref: "ref-1",
        summary: "Command failed",
        status: status,
        metadata: %{"workspace_id" => "workspace-1"},
        acknowledged_at: nil,
        dismissed_at: nil,
        inserted_at: nil,
        updated_at: nil
      }
    end

    defp evidence do
      %{
        source: "devide",
        workspace: %{
          id: "workspace-1",
          name: "Workspace",
          status: "active",
          lifecycle_status: "running",
          mode: "isolated",
          db_isolation: "isolated",
          last_observed_at: nil,
          last_changed_at: nil
        },
        reason: %{
          kind: "failed_run",
          severity: "warning",
          target_ref: "ref-1",
          summary: "Command failed"
        },
        related: %{workspace_id: "workspace-1", ref: "ref-1"},
        latest_runs: [
          %{
            "command_id" => "cmd-1",
            "status" => "failed",
            "exit_code" => 1,
            "finished_at" => "2026-05-12T00:00:00Z"
          }
        ],
        active_run: nil,
        proposal_risks: [
          %{
            "path" => "fix.diff",
            "risk" => "medium",
            "files_count" => 2,
            "overlapping_files" => ["lib/a.ex"]
          }
        ],
        policy: %{
          mode: "enforced",
          db_isolation: "isolated",
          attention_flags: ["failed_run"],
          recent_blocks: []
        },
        missing: []
      }
    end
  end

  test "approvals ls owns filters and json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Approvals.run(
                   [
                     "ls",
                     "--status",
                     "open",
                     "--source",
                     "devide",
                     "--workspace",
                     "workspace-1",
                     "--kind",
                     "failed_run",
                     "-n",
                     "10",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:list_approvals, opts}
    assert opts[:status] == "open"
    assert opts[:source] == "devide"
    assert opts[:workspace_id] == "workspace-1"
    assert opts[:kind] == "failed_run"
    assert opts[:limit] == 10

    assert %{"approvals" => [%{"approval_id" => "apr-1"}]} = Jason.decode!(output)
  end

  test "approvals ls validates before starting the app" do
    assert {:error, message} =
             Approvals.run(["ls", "--status", "bad"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported approval status"
    refute_received :started
    refute_received :list_approvals
  end

  test "approvals show renders safe-action workflow text" do
    output =
      capture_io(fn ->
        assert :ok =
                 Approvals.run(["show", "apr-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:approval_detail, "apr-1"}
    assert output =~ "approval apr-1"
    assert output =~ "safe-action workflow"
    assert output =~ "jx actions propose apr-1"
    assert output =~ "jx actions execute <action-id> --confirm"
  end

  test "approvals ack renders json through the workspace boundary" do
    output =
      capture_io(fn ->
        assert :ok =
                 Approvals.run(["ack", "apr-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:acknowledge_approval, "apr-1"}
    assert %{"approval_id" => "apr-1", "status" => "acknowledged"} = Jason.decode!(output)
  end

  test "approvals dismiss renders text through the workspace boundary" do
    output =
      capture_io(fn ->
        assert :ok =
                 Approvals.run(["dismiss", "apr-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:dismiss_approval, "apr-1"}
    assert output =~ "dismissed apr-1"
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
