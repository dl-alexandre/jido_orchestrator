defmodule JX.DevIDE.StateTest do
  use ExUnit.Case, async: false

  alias JX.DevIDE.{Client, Portfolio, State, Status, WorkspaceSnapshot}
  alias JX.Approvals.Approval
  alias JX.MonitorEvents.Event
  alias JX.Notifications.Notification
  alias JX.Repo
  alias JX.Workspace
  alias JXTest.Fixtures

  setup do
    cleanup_state()
    :ok
  end

  test "ingest persists snapshots and notifies only on new blocked changes" do
    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: "state-token")
    {:ok, server_state} = Agent.start_link(fn -> %{status_calls: 0, requests: []} end)

    Bypass.expect(bypass, fn conn ->
      Agent.update(server_state, fn state ->
        %{state | requests: [{conn.method, conn.request_path} | state.requests]}
      end)

      assert conn.method == "GET"
      route_state(conn, server_state)
    end)

    assert {:ok, first} = State.ingest(client)
    assert first.events == []
    assert first.notifications.saved == 0
    assert %{healthy: 1, blocked: 0} = State.summary()

    assert {:ok, second} = State.ingest(client)
    assert [%Event{kind: "devide.workspace.blocked", ref: "ws-1"}] = second.events
    assert second.notifications.saved == 1
    assert %{healthy: 0, blocked: 1} = State.summary()

    assert {:ok, third} = State.ingest(client)
    assert third.changes == []
    assert third.events == []
    assert third.notifications.saved == 0

    assert [%Notification{kind: "devide.workspace.blocked", ref: "ws-1", status: "unread"}] =
             Repo.all(Notification)

    requests = Agent.get(server_state, & &1.requests)
    assert Enum.all?(requests, fn {method, _path} -> method == "GET" end)
  end

  test "needs_review transitions create JX notifications" do
    healthy = status("status_ws1_watch_healthy.json")
    review = status("status_ws1_watch_review.json")

    first = Portfolio.from_statuses([healthy])
    second = Portfolio.from_statuses([review])

    assert %{notifications: %{saved: 0}} = State.ingest_portfolio(first)

    assert %{events: [%Event{kind: "devide.workspace.needs_review"}], notifications: %{saved: 1}} =
             State.ingest_portfolio(second)

    assert [%Notification{kind: "devide.workspace.needs_review", ref: "ws-1"}] =
             Repo.all(Notification)
  end

  test "portfolio summary includes stored DevIDE workspaces" do
    blocked = status("status_ws1_watch_blocked.json")
    portfolio = Portfolio.from_statuses([blocked])

    State.ingest_portfolio(portfolio)

    assert {:ok, summary} = Workspace.portfolio_summary(observe: false)
    assert summary.devide.total == 1
    assert summary.devide.blocked == 1
    assert summary.totals.devide_workspaces == 1
    assert summary.totals.devide_blocked == 1
  end

  defp route_state(%Plug.Conn{request_path: "/api/workspaces"} = conn, _server_state),
    do: Fixtures.devide_response(conn, 200, "workspaces_single.json")

  defp route_state(%Plug.Conn{request_path: "/api/workspaces/ws-1/status"} = conn, server_state) do
    status_call =
      Agent.get_and_update(server_state, fn state ->
        next = state.status_calls + 1
        {next, %{state | status_calls: next}}
      end)

    fixture =
      if status_call == 1,
        do: "status_ws1_watch_healthy.json",
        else: "status_ws1_watch_blocked.json"

    Fixtures.devide_response(conn, 200, fixture)
  end

  defp status(fixture), do: fixture |> Fixtures.devide_payload() |> Status.from_payload()

  defp cleanup_state do
    Repo.delete_all(Approval)
    Repo.delete_all(Notification)
    Repo.delete_all(Event)
    Repo.delete_all(WorkspaceSnapshot)
  end
end
