defmodule JX.DevIDE.ClientTest do
  use ExUnit.Case, async: true

  alias JX.DevIDE.Client
  alias JXTest.Fixtures

  @token "client-test-token"

  setup do
    bypass = Bypass.open()

    client =
      Client.new(
        base_url: "http://localhost:#{bypass.port}",
        api_token: @token
      )

    {:ok, bypass: bypass, client: client}
  end

  test "fetches DevIDE workspaces with bearer auth", %{bypass: bypass, client: client} do
    Bypass.expect(bypass, "GET", "/api/workspaces", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      Fixtures.devide_response(conn, 200, "workspaces_single.json")
    end)

    assert {:ok, [%{"id" => "ws-1", "name" => "alpha", "status" => "running"}]} =
             Client.workspaces(client)
  end

  test "maps 401 without leaking the token", %{bypass: bypass, client: client} do
    Bypass.expect(bypass, "GET", "/api/workspaces", fn conn ->
      Fixtures.devide_response(conn, 401, "error_unauthorized.json")
    end)

    assert {:error,
            %Client.Error{
              reason: :unauthorized,
              status: 401,
              failure_class: "claim_rejected"
            } = error} =
             Client.workspaces(client)

    refute Client.format_error(error) =~ @token
  end

  test "maps 503 from an unconfigured DevIDE API", %{bypass: bypass, client: client} do
    Bypass.expect(bypass, "GET", "/api/workspaces", fn conn ->
      Fixtures.devide_response(conn, 503, "error_api_token_not_configured.json")
    end)

    assert {:error, %Client.Error{reason: :unavailable, status: 503} = error} =
             Client.workspaces(client)

    assert Client.format_error(error) =~ "api_token_not_configured"
  end

  test "maps 404 for missing workspace", %{bypass: bypass, client: client} do
    Bypass.expect(bypass, "GET", "/api/workspaces/missing/status", fn conn ->
      Fixtures.devide_response(conn, 404, "error_not_found.json")
    end)

    assert {:error, %Client.Error{reason: :not_found, status: 404}} =
             Client.status(client, "missing")
  end

  test "starts allowlisted DevIDE runs with bearer auth and command_id body", %{
    bypass: bypass,
    client: client
  } do
    Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-1/runs", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"command_id" => "test"}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        201,
        Jason.encode!(%{
          id: "run-1",
          workspace_id: "ws-1",
          command_id: "test",
          status: "running"
        })
      )
    end)

    assert {:ok,
            %{
              status: 201,
              body: %{
                "id" => "run-1",
                "workspace_id" => "ws-1",
                "command_id" => "test",
                "status" => "running"
              }
            }} = Client.start_run_envelope(client, "ws-1", "test")
  end

  test "enqueues DevIDE runner assignments through the existing run endpoint", %{
    bypass: bypass,
    client: client
  } do
    Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-1/runs", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      assert Plug.Conn.get_req_header(conn, "x-jx-correlation-id") == ["corr-runner"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "command_id" => "test",
               "execution_protocol" => "jx.runner.v1",
               "jx_action_id" => "act-1",
               "jx_assignment_id" => "asgn-1",
               "jx_safe_action_kind" => "rerun_devide_command",
               "runner_requirements" => %{
                 "host" => "host-a",
                 "os" => "darwin",
                 "tools" => ["mix"]
               }
             }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        201,
        Jason.encode!(%{
          protocol: "jx.runner.v1",
          assignment: %{
            id: "dev-asgn-1",
            workspace_id: "ws-1",
            status: "queued",
            action: %{command_id: "test", argv: ["mix", "test", "--color"]},
            metadata: %{jx_assignment_id: "asgn-1"}
          }
        })
      )
    end)

    assert {:ok, %{body: %{"assignment" => %{"id" => "dev-asgn-1"}}}} =
             Client.enqueue_runner_assignment_envelope(client, "ws-1", "test",
               correlation_id: "corr-runner",
               jx_assignment_id: "asgn-1",
               jx_action_id: "act-1",
               jx_safe_action_kind: "rerun_devide_command",
               runner_requirements: %{host: "host-a", os: "darwin", tools: ["mix"]}
             )
  end

  test "fetches DevIDE runner replay", %{bypass: bypass, client: client} do
    Bypass.expect_once(bypass, "GET", "/api/runner/v1/assignments/dev-asgn-1", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          protocol: "jx.runner.v1",
          assignment: %{id: "dev-asgn-1", status: "succeeded", metadata: %{}},
          reports: []
        })
      )
    end)

    assert {:ok, %{"assignment" => %{"id" => "dev-asgn-1"}}} =
             Client.runner_assignment_replay(client, "dev-asgn-1")
  end
end
