defmodule JX.CLI.TimelineTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Timeline
  alias JX.OperationalEvents.Event

  defmodule FakeWorkspace do
    alias JX.OperationalEvents.Event

    def operational_timeline(scope, id, opts) do
      send(self(), {:operational_timeline, scope, id, opts})

      %{
        scope: scope,
        id: id,
        rebuilt: %{events: opts[:limit], status: "ok"},
        events: [
          event(%{
            kind: "safe_action.execute_denied",
            entity_type: "action",
            entity_id: "act-1",
            action_id: "act-1",
            payload: ~s({"denial":{"outcome":"blocked","reason":"policy"}})
          })
        ]
      }
    end

    defp event(attrs) do
      %Event{
        event_id: Map.get(attrs, :event_id, "evt-1"),
        correlation_id: Map.get(attrs, :correlation_id, "corr-1"),
        source: Map.get(attrs, :source, "test"),
        kind: Map.get(attrs, :kind, "workspace.updated"),
        entity_type: Map.get(attrs, :entity_type, "workspace"),
        entity_id: Map.get(attrs, :entity_id, "workspace-1"),
        workspace_id: Map.get(attrs, :workspace_id, "workspace-1"),
        approval_id: Map.get(attrs, :approval_id, "apr-1"),
        action_id: Map.get(attrs, :action_id, "act-1"),
        lease_id: Map.get(attrs, :lease_id, "lease-1"),
        owner: Map.get(attrs, :owner, "operator"),
        severity: Map.get(attrs, :severity, "notice"),
        summary: Map.get(attrs, :summary, "timeline event"),
        payload: Map.get(attrs, :payload, "{}"),
        inserted_at: "2026-05-12T00:00:00Z"
      }
    end
  end

  test "timeline routes scope id and limit with json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Timeline.run(["workspace", "workspace-1", "-n", "7", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:operational_timeline, "workspace", "workspace-1", opts}
    assert opts[:limit] == 7

    assert %{
             "scope" => "workspace",
             "id" => "workspace-1",
             "rebuilt" => %{"events" => 7, "status" => "ok"},
             "events" => [
               %{
                 "event_id" => "evt-1",
                 "payload" => %{"denial" => %{"outcome" => "blocked", "reason" => "policy"}}
               }
             ]
           } = Jason.decode!(output)
  end

  test "timeline text rendering includes operational next hints" do
    output =
      capture_io(fn ->
        assert :ok =
                 Timeline.run(["action", "act-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "timeline action act-1"
    assert output =~ "safe_action.execute_denied"
    assert output =~ "outcome=blocked"
    assert output =~ "next=jx actions show act-1"
  end

  test "timeline validates scope before starting the app" do
    assert {:error, message} =
             Timeline.run(["bad", "id"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported timeline scope"
    refute_received :started
    refute_received :operational_timeline
  end

  test "timeline validates limit before starting the app" do
    assert {:error, message} =
             Timeline.run(["workspace", "workspace-1", "-n", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "n must be a positive integer"
    refute_received :started
    refute_received :operational_timeline
  end

  test "timeline requires scope and id" do
    assert {:error, message} =
             Timeline.run(["workspace"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message ==
             "usage: jx timeline workspace|approval|action|assignment|agent|runner|session <id> [-n 100] [--json]"

    refute_received :started
  end

  defp start_app_callback do
    fn ->
      send(self(), :started)
      :ok
    end
  end
end
