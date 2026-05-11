defmodule JX.DevIDE.PortfolioTest do
  use ExUnit.Case, async: true

  alias JX.DevIDE.{Client, Portfolio}
  alias JXTest.Fixtures

  @token "portfolio-token"

  test "portfolio fetch groups healthy, blocked, and needs_review from DevIDE state" do
    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: @token)

    Bypass.expect(bypass, fn conn ->
      assert conn.method == "GET"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      route(conn)
    end)

    assert {:ok, portfolio} = Portfolio.fetch(client)

    assert Enum.map(portfolio.healthy, & &1.workspace.id) == ["healthy"]
    assert Enum.map(portfolio.blocked, & &1.workspace.id) == ["blocked"]
    assert Enum.map(portfolio.needs_review, & &1.workspace.id) == ["review"]
    assert portfolio.total == 3

    [blocked] = portfolio.blocked
    assert "db_isolation:shared_stage" in blocked.attention_flags
    assert "policy_blocked:recent" in blocked.attention_flags

    [review] = portfolio.needs_review
    assert "proposal:conflict" in review.attention_flags
  end

  defp route(%Plug.Conn{request_path: "/api/workspaces"} = conn),
    do: Fixtures.devide_response(conn, 200, "workspaces_portfolio.json")

  defp route(%Plug.Conn{request_path: "/api/workspaces/" <> rest} = conn) do
    [workspace_id, endpoint] = String.split(rest, "/", parts: 2)
    Fixtures.devide_response(conn, 200, fixture(workspace_id, endpoint))
  end

  defp fixture("healthy", "status"), do: "status_healthy.json"
  defp fixture("blocked", "status"), do: "status_blocked_shared_stage.json"
  defp fixture("review", "status"), do: "status_review.json"
  defp fixture(_workspace_id, "runs"), do: "runs_success.json"
  defp fixture("review", "proposals"), do: "proposals_conflict.json"
  defp fixture(_workspace_id, "proposals"), do: "proposals_empty.json"
  defp fixture("blocked", "audit"), do: "audit_policy_blocked.json"
  defp fixture(_workspace_id, "audit"), do: "audit_empty.json"
end
