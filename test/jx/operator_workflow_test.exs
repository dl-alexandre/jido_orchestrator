defmodule JX.OperatorWorkflowTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JX.Approvals
  alias JX.Approvals.Approval
  alias JX.CLI
  alias JX.CLI.DevIDE, as: DevIDECLI
  alias JX.DevIDE.{Client, Portfolio, State, Status, WorkspaceSnapshot}
  alias JX.MonitorEvents.Event
  alias JX.Notifications.Notification
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Repo
  alias JX.SafeActions.ExecutionEvent
  alias JXTest.Fixtures

  @token "workflow-token"

  setup do
    cleanup_state()
    :ok
  end

  test "operator can move from DevIDE attention to approved safe action audit" do
    assert %{approvals: %{saved: 3}} =
             State.ingest_portfolio(portfolio("status_ws1_watch_blocked.json"))

    assert {:ok, risk_client} = devide_risk_client()
    assert {0, risks_output} = DevIDECLI.run(["devide", "risks"], client: risk_client)
    assert risks_output =~ "operator_flow"
    assert risks_output =~ "jx approvals ls --source devide"

    State.ingest_portfolio(portfolio("status_ws1_watch_healthy.json"))
    approval = Approvals.list(kind: "failed_run", status: "open") |> List.first()

    list_output =
      capture_io(fn -> assert :ok = CLI.run(["approvals", "ls", "--source", "devide"]) end)

    assert list_output =~ approval.approval_id
    assert list_output =~ "next: jx approvals show <id>"
    assert list_output =~ "safe action: jx actions propose <id>"

    show_output =
      capture_io(fn -> assert :ok = CLI.run(["approvals", "show", approval.approval_id]) end)

    assert show_output =~ "evidence freshness"
    assert show_output =~ "source: stored_devide_snapshot"
    assert show_output =~ "last_observed_at:"
    assert show_output =~ "safe-action workflow"
    assert show_output =~ "propose rerun: jx actions propose #{approval.approval_id}"
    assert show_output =~ "audit: jx actions history #{approval.approval_id}"

    propose_output =
      capture_io(fn -> assert :ok = CLI.run(["actions", "propose", approval.approval_id]) end)

    action_id = extract_action_id!(propose_output, "proposed")
    assert propose_output =~ "next: jx actions dry-run #{action_id}"
    assert propose_output =~ "execute: jx actions execute #{action_id} --confirm"
    assert propose_output =~ "audit: jx actions history #{approval.approval_id}"

    dry_run_output = capture_io(fn -> assert :ok = CLI.run(["actions", "dry-run", action_id]) end)
    assert dry_run_output =~ "would do:"
    assert dry_run_output =~ "next: jx actions execute #{action_id} --confirm"

    bypass = Bypass.open()
    put_devide_env!(bypass.port)

    Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-1/runs", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"command_id" => "test"}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        201,
        Jason.encode!(%{id: "run-workflow", command_id: "test", status: "running"})
      )
    end)

    execute_output =
      capture_io(fn -> assert :ok = CLI.run(["actions", "execute", action_id, "--confirm"]) end)

    assert execute_output =~ "executed #{action_id}"
    assert execute_output =~ "run: run-workflow"
    assert execute_output =~ "audit: jx actions history #{approval.approval_id}"

    action_show_output =
      capture_io(fn -> assert :ok = CLI.run(["actions", "show", action_id]) end)

    assert action_show_output =~ "approval_detail: jx approvals show #{approval.approval_id}"
    assert action_show_output =~ "devide_status: jx devide status ws-1"
    assert action_show_output =~ "correlation_id: corr-"

    history_output =
      capture_io(fn -> assert :ok = CLI.run(["actions", "history", approval.approval_id]) end)

    assert history_output =~ "approval_detail: jx approvals show #{approval.approval_id}"
    assert history_output =~ "kind=executed outcome=success"
    assert history_output =~ "kind=approval_acknowledged outcome=approval_acknowledged"

    assert Repo.get_by!(Approval, approval_id: approval.approval_id).status == "acknowledged"
    assert Repo.get_by!(OrchestrationAction, action_id: action_id).status == "executed"
  end

  defp portfolio(status_fixture) do
    status_fixture
    |> Fixtures.devide_payload()
    |> Status.from_payload()
    |> then(&Portfolio.from_statuses([&1]))
  end

  defp devide_risk_client do
    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: @token)

    Bypass.expect(bypass, fn conn ->
      assert conn.method == "GET"
      route_portfolio(conn)
    end)

    {:ok, client}
  end

  defp route_portfolio(%Plug.Conn{request_path: "/api/workspaces"} = conn),
    do: Fixtures.devide_response(conn, 200, "workspaces_portfolio.json")

  defp route_portfolio(%Plug.Conn{request_path: "/api/workspaces/" <> rest} = conn) do
    [workspace_id, endpoint] = String.split(rest, "/", parts: 2)
    Fixtures.devide_response(conn, 200, portfolio_fixture(workspace_id, endpoint))
  end

  defp portfolio_fixture("healthy", "status"), do: "status_healthy.json"
  defp portfolio_fixture("blocked", "status"), do: "status_blocked_unsafe.json"
  defp portfolio_fixture("review", "status"), do: "status_review.json"
  defp portfolio_fixture(_workspace_id, "runs"), do: "runs_success.json"
  defp portfolio_fixture("review", "proposals"), do: "proposals_overlap.json"
  defp portfolio_fixture(_workspace_id, "proposals"), do: "proposals_empty.json"
  defp portfolio_fixture(_workspace_id, "audit"), do: "audit_empty.json"

  defp put_devide_env!(port) do
    previous_url = System.get_env("JX_DEVIDE_URL")
    previous_token = System.get_env("JX_DEVIDE_API_TOKEN")

    System.put_env("JX_DEVIDE_URL", "http://localhost:#{port}")
    System.put_env("JX_DEVIDE_API_TOKEN", @token)

    on_exit(fn ->
      restore_env("JX_DEVIDE_URL", previous_url)
      restore_env("JX_DEVIDE_API_TOKEN", previous_token)
    end)
  end

  defp extract_action_id!(output, label) do
    regex = Regex.compile!("(?m)^#{label} (act-[a-f0-9]+)$")
    [_, action_id] = Regex.run(regex, output)
    action_id
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp cleanup_state do
    Repo.delete_all(ExecutionEvent)
    Repo.delete_all(OrchestrationAction)
    Repo.delete_all(Approval)
    Repo.delete_all(Notification)
    Repo.delete_all(Event)
    Repo.delete_all(WorkspaceSnapshot)
  end
end
