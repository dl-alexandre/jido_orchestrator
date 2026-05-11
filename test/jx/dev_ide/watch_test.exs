defmodule JX.DevIDE.WatchTest do
  use ExUnit.Case, async: true

  alias JX.DevIDE.{Client, Watch}
  alias JXTest.Fixtures

  test "watch loop stops cleanly when it receives a trapped SIGINT message" do
    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: "watch-token")
    parent = self()

    Bypass.stub(bypass, "GET", "/api/workspaces", fn conn ->
      Fixtures.devide_response(conn, 200, "workspaces_empty.json")
    end)

    task =
      Task.async(fn ->
        Watch.run(client,
          interval_ms: 1_000,
          output: fn chunk -> send(parent, {:watch_output, chunk}) end
        )
      end)

    send(task.pid, {:signal, :sigint})

    assert Task.await(task, 1_000) == :ok
    assert_receive {:watch_output, "watch stopped\n"}
  end
end
