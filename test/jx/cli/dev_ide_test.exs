defmodule JX.CLI.DevIDETest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JX.CLI
  alias JX.CLI.DevIDE, as: DevIDECLI
  alias JX.DevIDE.{Client, State, WorkspaceSnapshot}
  alias JX.Approvals.Approval
  alias JX.MonitorEvents.Event
  alias JX.Notifications.Notification
  alias JX.Repo
  alias JXTest.Fixtures

  @token "cli-token"

  test "workspaces command renders workspace summaries" do
    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: @token)

    Bypass.expect(bypass, "GET", "/api/workspaces", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      Fixtures.devide_response(conn, 200, "workspaces_single.json")
    end)

    assert {0, output} = DevIDECLI.run(["devide", "workspaces"], client: client)
    assert output =~ "workspaces"
    assert output =~ "ws-1"
    assert output =~ "alpha"
    assert output =~ "running"
  end

  test "top-level jx CLI dispatches devide commands through environment config" do
    bypass = Bypass.open()
    previous_url = System.get_env("JX_DEVIDE_URL")
    previous_token = System.get_env("JX_DEVIDE_API_TOKEN")

    System.put_env("JX_DEVIDE_URL", "http://localhost:#{bypass.port}")
    System.put_env("JX_DEVIDE_API_TOKEN", @token)

    on_exit(fn ->
      restore_env("JX_DEVIDE_URL", previous_url)
      restore_env("JX_DEVIDE_API_TOKEN", previous_token)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      Fixtures.devide_response(conn, 200, "workspaces_single.json")
    end)

    output = capture_io(fn -> assert :ok = CLI.run(["devide", "workspaces"]) end)

    assert output =~ "ws-1"
    assert output =~ "alpha"
  end

  test "status command renders runs, proposal risks, and recent audit blocks without secrets" do
    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: @token)

    Bypass.expect(bypass, fn conn ->
      assert conn.method == "GET"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      route_status(conn)
    end)

    assert {0, output} = DevIDECLI.run(["devide", "status", "ws-1"], client: client)

    assert output =~ "workspace"
    assert output =~ "id: ws-1"
    assert output =~ "latest_runs"
    assert output =~ "test succeeded"
    assert output =~ "proposal_risks"
    assert output =~ ".opencode/proposals/fix.diff invalid"
    assert output =~ "recent_blocks"
    assert output =~ "policy.blocked"

    refute output =~ "super-secret"
    refute output =~ @token
  end

  test "portfolio and risks commands use only read-only DevIDE endpoints" do
    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: @token)
    {:ok, agent} = Agent.start_link(fn -> [] end)

    Bypass.expect(bypass, fn conn ->
      Agent.update(agent, &[{conn.method, conn.request_path} | &1])
      assert conn.method == "GET"
      route_portfolio(conn)
    end)

    assert {0, portfolio_output} = DevIDECLI.run(["devide", "portfolio"], client: client)
    assert portfolio_output =~ "healthy: 1"
    assert portfolio_output =~ "blocked: 1"
    assert portfolio_output =~ "needs_review: 1"

    assert {0, risks_output} = DevIDECLI.run(["devide", "risks"], client: client)
    assert risks_output =~ "blocked"
    assert risks_output =~ "needs_review"

    methods = Agent.get(agent, &Enum.map(&1, fn {method, _path} -> method end))
    assert Enum.all?(methods, &(&1 == "GET"))
  end

  test "watch command suppresses unchanged polls and emits new attention states" do
    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: @token)
    {:ok, server_state} = Agent.start_link(fn -> %{status_calls: 0, requests: []} end)
    {:ok, output} = Agent.start_link(fn -> "" end)

    Bypass.expect(bypass, fn conn ->
      Agent.update(server_state, fn state ->
        %{state | requests: [{conn.method, conn.request_path} | state.requests]}
      end)

      assert conn.method == "GET"
      route_watch(conn, server_state)
    end)

    writer = fn chunk -> Agent.update(output, &(&1 <> chunk)) end

    assert {0, ""} =
             DevIDECLI.run(
               ["devide", "watch", "--interval-ms", "1", "--max-polls", "3"],
               client: client,
               writer: writer
             )

    rendered = Agent.get(output, & &1)
    assert rendered =~ "! healthy->blocked ws-1 alpha"
    assert rendered =~ "proposal:conflict"
    assert rendered =~ "active_run:failed"
    assert rendered =~ "db_isolation:unsafe"
    assert rendered =~ "next=\"jx approvals ls --source devide --workspace ws-1\""
    assert rendered |> String.split("\n", trim: true) |> length() == 1

    requests = Agent.get(server_state, & &1.requests)
    assert Enum.all?(requests, fn {method, _path} -> method == "GET" end)
    refute Enum.any?(requests, fn {_method, path} -> String.ends_with?(path, "/runs") end)
    refute Enum.any?(requests, fn {_method, path} -> String.ends_with?(path, "/proposals") end)
    refute Enum.any?(requests, fn {_method, path} -> String.ends_with?(path, "/audit") end)
  end

  test "watch command can persist DevIDE state and notifications" do
    cleanup_devide_state()

    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: @token)
    {:ok, server_state} = Agent.start_link(fn -> %{status_calls: 0, requests: []} end)
    {:ok, output} = Agent.start_link(fn -> "" end)

    Bypass.expect(bypass, fn conn ->
      Agent.update(server_state, fn state ->
        %{state | requests: [{conn.method, conn.request_path} | state.requests]}
      end)

      assert conn.method == "GET"
      route_watch(conn, server_state)
    end)

    writer = fn chunk -> Agent.update(output, &(&1 <> chunk)) end

    assert {0, ""} =
             DevIDECLI.run(
               ["devide", "watch", "--state", "--interval-ms", "1", "--max-polls", "3"],
               client: client,
               writer: writer
             )

    assert Agent.get(output, & &1) =~ "! healthy->blocked ws-1 alpha"
    assert Agent.get(output, & &1) =~ "jx approvals ls --source devide --workspace ws-1"
    assert %{blocked: 1, total: 1} = State.summary()

    assert [%Notification{kind: "devide.workspace.blocked", ref: "ws-1"}] =
             Repo.all(Notification)

    requests = Agent.get(server_state, & &1.requests)
    assert Enum.all?(requests, fn {method, _path} -> method == "GET" end)
  end

  test "status command reports missing workspaces cleanly" do
    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: @token)

    Bypass.expect(bypass, "GET", "/api/workspaces/nope/status", fn conn ->
      Fixtures.devide_response(conn, 404, "error_not_found.json")
    end)

    assert {1, output} = DevIDECLI.run(["devide", "status", "nope"], client: client)
    assert output =~ "workspace was not found"
    refute output =~ @token
  end

  defp route_status(%Plug.Conn{request_path: "/api/workspaces/ws-1/status"} = conn),
    do: Fixtures.devide_response(conn, 200, "status_ws1_detail.json")

  defp route_status(%Plug.Conn{request_path: "/api/workspaces/ws-1/runs"} = conn),
    do: Fixtures.devide_response(conn, 200, "runs_success_secret.json")

  defp route_status(%Plug.Conn{request_path: "/api/workspaces/ws-1/proposals"} = conn),
    do: Fixtures.devide_response(conn, 200, "proposals_invalid.json")

  defp route_status(%Plug.Conn{request_path: "/api/workspaces/ws-1/audit"} = conn),
    do: Fixtures.devide_response(conn, 200, "audit_policy_blocked_needs_review.json")

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

  defp route_watch(%Plug.Conn{request_path: "/api/workspaces"} = conn, _server_state),
    do: Fixtures.devide_response(conn, 200, "workspaces_single.json")

  defp route_watch(%Plug.Conn{request_path: "/api/workspaces/ws-1/status"} = conn, server_state) do
    status_call =
      Agent.get_and_update(server_state, fn state ->
        next = state.status_calls + 1
        {next, %{state | status_calls: next}}
      end)

    fixture =
      if status_call in [1, 2],
        do: "status_ws1_watch_healthy.json",
        else: "status_ws1_watch_blocked.json"

    Fixtures.devide_response(conn, 200, fixture)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp cleanup_devide_state do
    Repo.delete_all(Approval)
    Repo.delete_all(Notification)
    Repo.delete_all(Event)
    Repo.delete_all(WorkspaceSnapshot)
  end
end
