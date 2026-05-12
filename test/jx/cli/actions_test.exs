defmodule JX.CLI.ActionsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Actions

  defmodule FakeWorkspace do
    def list_orchestration_actions(opts) do
      send(self(), {:list_orchestration_actions, opts})
      [action()]
    end

    def show_action(action_id) do
      send(self(), {:show_action, action_id})

      {:ok,
       %{
         action: action(action_id),
         payload: payload(),
         events: [event(action_id)],
         guidance: "Retry"
       }}
    end

    def action_history(approval_id) do
      send(self(), {:action_history, approval_id})

      {:ok,
       %{
         approval_id: approval_id,
         actions: [action("act-1")],
         events: [event("act-1")],
         guidance: %{"act-1" => "Retry with confirmation"}
       }}
    end

    def propose_action(approval_id, opts) do
      send(self(), {:propose_action, approval_id, opts})
      {:ok, result("act-proposed", executed: false)}
    end

    def dry_run_action(action_id, opts) do
      send(self(), {:dry_run_action, action_id, opts})
      {:ok, result(action_id, executed: false)}
    end

    def execute_action(action_id, opts) do
      send(self(), {:execute_action, action_id, opts})

      if Keyword.get(opts, :confirm) do
        {:ok, result(action_id, executed: true)}
      else
        {:error, :confirmation_required}
      end
    end

    defp result(action_id, opts) do
      executed? = Keyword.fetch!(opts, :executed)

      %{
        action: action(action_id, if(executed?, do: "executed", else: "planned")),
        safe_action: %{
          kind: "rerun_devide_command",
          approval_id: "apr-1",
          workspace_id: "workspace-1",
          command_id: "cmd-1",
          db_isolation: "isolated"
        },
        would_do: "rerun DevIDE command cmd-1",
        dry_run_only: !executed?,
        executed: executed?,
        mode: if(executed?, do: "execute", else: "dry_run"),
        run: if(executed?, do: %{"id" => "run-1", "status" => "ok"}, else: nil),
        devide_response: nil
      }
    end

    defp action(action_id \\ "act-1", status \\ "planned") do
      %{
        action_id: action_id,
        queue_key: "action:#{action_id}",
        requested: "actions.propose",
        source: "devide",
        recommendation_id: "rec-1",
        action: "rerun_devide_command",
        safety: "gated",
        ref: "apr-1",
        target: "workspace-1",
        status: status,
        reason: "DevIDE command needs rerun",
        error: nil,
        result_summary: nil,
        outcome: nil,
        outcome_reason: nil,
        payload: payload(),
        scheduled_at: nil,
        executed_at: nil,
        completed_at: nil,
        inserted_at: nil,
        updated_at: nil
      }
    end

    defp event(action_id) do
      %{
        event_id: "evt-1",
        correlation_id: "corr-1",
        action_id: action_id,
        approval_id: "apr-1",
        workspace_id: "workspace-1",
        command_id: "cmd-1",
        kind: "dry_run",
        outcome: "helpful",
        reason: "safe dry run",
        payload: payload(),
        inserted_at: nil
      }
    end

    defp payload do
      %{
        "approval_id" => "apr-1",
        "workspace_id" => "workspace-1",
        "command_id" => "cmd-1",
        "db_isolation" => "isolated",
        "target_ref" => "ref-1",
        "correlation_id" => "corr-1"
      }
    end
  end

  test "actions ls owns parsing and json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Actions.run(
                   [
                     "ls",
                     "--source",
                     "devide",
                     "--ref",
                     "apr-1",
                     "--action",
                     "rerun_devide_command",
                     "--status",
                     "planned",
                     "--outcome",
                     "helpful",
                     "-n",
                     "10",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:list_orchestration_actions, opts}
    assert opts[:source] == "devide"
    assert opts[:ref] == "apr-1"
    assert opts[:action] == "rerun_devide_command"
    assert opts[:status] == "planned"
    assert opts[:outcome] == "helpful"
    assert opts[:limit] == 10

    assert %{"actions" => [%{"action_id" => "act-1"}]} = Jason.decode!(output)
  end

  test "actions ls validates before starting the app" do
    assert {:error, message} =
             Actions.run(["ls", "--status", "bad"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported action status"
    refute_received :started
    refute_received :list_orchestration_actions
  end

  test "actions propose defaults to rerun action kind" do
    output =
      capture_io(fn ->
        assert :ok =
                 Actions.run(["propose", "apr-1", "--owner", "operator"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:propose_action, "apr-1", [kind: "rerun_devide_command", owner: "operator"]}
    assert output =~ "proposed act-proposed"
    assert output =~ "execute: jx actions execute act-proposed --confirm"
  end

  test "actions propose rejects mismatched kind aliases before starting" do
    assert {:error, message} =
             Actions.run(
               [
                 "propose",
                 "apr-1",
                 "--kind",
                 "rerun_devide_command",
                 "--action",
                 "acknowledge_approval"
               ],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "--kind and --action must match when both are provided"
    refute_received :started
    refute_received :propose_action
  end

  test "actions execute without confirm dry-runs and refuses side effect" do
    output =
      capture_io(fn ->
        assert {:error, message} =
                 Actions.run(["execute", "act-1", "--owner", "operator"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )

        assert message == "confirmation required; pass --confirm to execute this action"
      end)

    assert_received :started
    assert_received {:dry_run_action, "act-1", [owner: "operator"]}
    assert_received {:execute_action, "act-1", [confirm: false]}
    assert output =~ "dry run act-1"
    assert output =~ "execution: requires --confirm"
  end

  test "actions execute with confirm performs the side effect" do
    output =
      capture_io(fn ->
        assert :ok =
                 Actions.run(["execute", "act-1", "--confirm", "--owner", "operator"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:execute_action, "act-1", [confirm: true, owner: "operator"]}
    refute_received {:dry_run_action, "act-1", _opts}
    assert output =~ "executed act-1"
    assert output =~ "execution: executed"
  end

  test "actions show renders stable operator inspection text" do
    output =
      capture_io(fn ->
        assert :ok =
                 Actions.run(["show", "act-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:show_action, "act-1"}
    assert output =~ "action act-1"
    assert output =~ "correlation_id: corr-1"
    assert output =~ "approval_detail: jx approvals show apr-1"
  end

  test "actions history renders json through the workspace boundary" do
    output =
      capture_io(fn ->
        assert :ok =
                 Actions.run(["history", "apr-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:action_history, "apr-1"}

    assert %{
             "approval_id" => "apr-1",
             "actions" => [%{"action_id" => "act-1"}],
             "events" => [%{"event_id" => "evt-1"}]
           } = Jason.decode!(output)
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
