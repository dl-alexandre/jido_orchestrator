defmodule JX.CLI.EventsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Events

  defmodule FakeWorkspace do
    def operational_events_check(opts) do
      send(self(), {:operational_events_check, opts})

      %{
        status: "ok",
        checked_at: "2026-05-12T00:00:00Z",
        events: opts[:limit],
        rebuilt: %{events: opts[:limit], issues: 0},
        queue: %{open_approvals: 1, planned_actions: 2, active_leases: 3},
        issues: [],
        next: []
      }
    end

    def list_monitor_events(opts) do
      send(self(), {:list_monitor_events, opts})

      [
        event(%{
          id: 12,
          ref: opts[:ref],
          kind: opts[:kind],
          severity: opts[:severity] || "notice"
        })
      ]
    end

    def unread_monitor_events(opts) do
      send(self(), {:unread_monitor_events, opts})

      {:ok,
       %{
         consumer: opts[:consumer] || "default",
         cursor: cursor(%{consumer: opts[:consumer] || "default", last_event_id: 4}),
         latest_event_id: 12,
         unread_total: 8,
         matching_unread_total: 1,
         returned: 1,
         events: [event(%{id: 12, ref: opts[:ref], kind: opts[:kind] || "session.ready"})]
       }}
    end

    def acknowledge_monitor_events(opts) do
      send(self(), {:acknowledge_monitor_events, opts})
      {:ok, cursor(%{consumer: opts[:consumer] || "default", last_event_id: opts[:to_id] || 12})}
    end

    def monitor_event_status(opts) do
      send(self(), {:monitor_event_status, opts})

      %{
        consumer: opts[:consumer] || "default",
        cursor: cursor(%{consumer: opts[:consumer] || "default", last_event_id: 12}),
        latest_event_id: 12,
        unread_total: 0,
        caught_up: true,
        latest_event: event(%{id: 12})
      }
    end

    defp cursor(attrs) do
      %{
        consumer: Map.get(attrs, :consumer, "default"),
        source: "monitor_events",
        last_event_id: Map.get(attrs, :last_event_id, 0),
        last_seen_at: "2026-05-12T00:00:00Z",
        updated_at: "2026-05-12T00:01:00Z"
      }
    end

    defp event(attrs) do
      %{
        id: Map.get(attrs, :id, 1),
        event_id: "evt-#{Map.get(attrs, :id, 1)}",
        kind: Map.get(attrs, :kind, "session.ready"),
        severity: Map.get(attrs, :severity, "notice"),
        ref: Map.get(attrs, :ref, "ref-1"),
        project: "saysure",
        session_type: "agent",
        session_kind: "tmux",
        control_mode: "managed",
        work_state: "running",
        action: "review",
        summary: "event summary",
        fingerprint: "fingerprint",
        payload: ~s({"ok":true}),
        inserted_at: "2026-05-12T00:00:00Z"
      }
    end
  end

  test "events check owns limit parsing and json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Events.run(["check", "-n", "42", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:operational_events_check, opts}
    assert opts[:limit] == 42

    assert %{"status" => "ok", "events" => 42} = Jason.decode!(output)
  end

  test "events ls validates severity before starting the app" do
    assert {:error, message} =
             Events.run(["ls", "--severity", "bad"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported monitor severity"
    refute_received :started
    refute_received :list_monitor_events
  end

  test "events ls routes filters through workspace" do
    output =
      capture_io(fn ->
        assert :ok =
                 Events.run(
                   [
                     "ls",
                     "--since",
                     "7",
                     "--ref",
                     "ref-1",
                     "--kind",
                     "session.ready",
                     "--severity",
                     "notice",
                     "-n",
                     "3",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:list_monitor_events, opts}
    assert opts[:since_id] == 7
    assert opts[:ref] == "ref-1"
    assert opts[:kind] == "session.ready"
    assert opts[:severity] == "notice"
    assert opts[:limit] == 3

    assert %{"events" => [%{"id" => 12, "payload" => %{"ok" => true}}]} = Jason.decode!(output)
  end

  test "events unread routes consumer and filters" do
    output =
      capture_io(fn ->
        assert :ok =
                 Events.run(
                   ["unread", "--consumer", "codex", "--ref", "ref-1", "-n", "4", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:unread_monitor_events, opts}
    assert opts[:consumer] == "codex"
    assert opts[:ref] == "ref-1"
    assert opts[:limit] == 4

    assert %{"consumer" => "codex", "events" => [%{"id" => 12}]} = Jason.decode!(output)
  end

  test "events ack requires a target before side effects" do
    assert {:error, message} =
             Events.run(["ack"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "jx events ack requires --to <id> or --latest"
    refute_received :started
    refute_received :acknowledge_monitor_events
  end

  test "events ack rejects latest with explicit target before side effects" do
    assert {:error, message} =
             Events.run(["ack", "--latest", "--to", "12"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "jx events ack accepts either --to <id> or --latest, not both"
    refute_received :started
    refute_received :acknowledge_monitor_events
  end

  test "events ack routes latest cursor through workspace" do
    output =
      capture_io(fn ->
        assert :ok =
                 Events.run(["ack", "--consumer", "codex", "--latest", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:acknowledge_monitor_events, opts}
    assert opts[:consumer] == "codex"
    assert opts[:to_id] == nil

    assert %{"cursor" => %{"consumer" => "codex", "last_event_id" => 12}} =
             Jason.decode!(output)
  end

  test "events cursor renders status" do
    output =
      capture_io(fn ->
        assert :ok =
                 Events.run(["cursor", "--consumer", "codex", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:monitor_event_status, opts}
    assert opts[:consumer] == "codex"

    assert %{"consumer" => "codex", "caught_up" => true, "latest_event" => %{"id" => 12}} =
             Jason.decode!(output)
  end

  test "unknown events command returns focused usage" do
    assert {:error, message} =
             Events.run(["unknown"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage: jx events check"
    assert message =~ "jx events cursor"
  end

  defp start_app_callback do
    fn ->
      send(self(), :started)
      :ok
    end
  end
end
