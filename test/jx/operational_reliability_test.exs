defmodule JX.OperationalReliabilityTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias JX.Approvals.Approval
  alias JX.CLI
  alias JX.DevIDE.{Client, WorkspaceSnapshot}
  alias JX.MonitorEvents.Event, as: MonitorEvent
  alias JX.Notifications.Notification
  alias JX.OperationalEvents
  alias JX.OperationalEvents.Event, as: OperationalEvent
  alias JX.OperationalEvents.Reducer
  alias JX.OperationalLeases
  alias JX.OperationalLeases.Lease
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Repo
  alias JX.SafeActions
  alias JX.SafeActions.ExecutionEvent
  alias JX.Workspace

  setup do
    cleanup_state()
    :ok
  end

  test "reducers replay deterministically and diagnostics flag corrupt or future events safely" do
    {:ok, _event} =
      OperationalEvents.record(%{
        source: "test",
        kind: "test.workspace",
        entity_type: "workspace",
        entity_id: "ws-replay",
        workspace_id: "ws-replay",
        payload: %{status: "blocked", event_version: 1}
      })

    {:ok, _event} =
      OperationalEvents.record(%{
        source: "test",
        kind: "test.approval",
        entity_type: "approval",
        entity_id: "apr-replay",
        workspace_id: "ws-replay",
        approval_id: "apr-replay",
        payload: %{status: "open", event_version: 1}
      })

    events = OperationalEvents.list(limit: 50)
    assert Reducer.rebuild(events) == Reducer.rebuild(Enum.reverse(events))

    insert_raw_operational_event!(%{
      event_id: "ope-corrupt",
      correlation_id: "",
      kind: "future.corrupt",
      entity_type: "future_widget",
      entity_id: "future-1",
      workspace_id: "ws-replay",
      payload: "{not-json"
    })

    insert_raw_operational_event!(%{
      event_id: "ope-future",
      correlation_id: "corr-future",
      kind: "future.action",
      entity_type: "action",
      entity_id: "act-future",
      action_id: "act-future",
      workspace_id: "ws-replay",
      payload: Jason.encode!(%{event_version: 99, status: "planned"})
    })

    rebuilt = OperationalEvents.list(limit: 50) |> Reducer.rebuild()
    assert rebuilt.workspaces["ws-replay"].status == "blocked"
    assert rebuilt.approvals["apr-replay"].status == "open"
    assert rebuilt.actions["act-future"].status == "planned"

    report = Workspace.operational_events_check(limit: 50)
    problems = report.issues |> Enum.map(& &1.problem) |> MapSet.new()

    assert report.status == "warning"

    assert MapSet.subset?(
             MapSet.new(
               ~w(corrupt_payload unknown_entity_type future_event_version missing_correlation_id)
             ),
             problems
           )

    output =
      capture_io(fn ->
        assert :ok = CLI.run(["events", "check", "-n", "50"])
      end)

    assert output =~ "operational event check: warning"
    assert output =~ "corrupt_payload"
    assert output =~ "unknown_entity_type"
    assert output =~ "future_event_version"
  end

  test "concurrent lease acquisition and post-expiration claims leave one active owner" do
    acquisition_results =
      1..12
      |> Task.async_stream(
        fn index ->
          OperationalLeases.acquire("approval", "apr-race", "op-#{index}", ttl_seconds: 60)
        end,
        max_concurrency: 12,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(acquisition_results, &match?({:ok, %Lease{}}, &1)) == 1
    assert active_lease_count("approval", "apr-race") == 1

    %Lease{} = active = OperationalLeases.active("approval", "apr-race")
    later = DateTime.add(active.expires_at, 1, :second)

    post_expiration_results =
      1..8
      |> Task.async_stream(
        fn index ->
          OperationalLeases.acquire("approval", "apr-race", "after-#{index}",
            now: later,
            ttl_seconds: 60
          )
        end,
        max_concurrency: 8,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(post_expiration_results, &match?({:ok, %Lease{}}, &1)) == 1
    assert active_lease_count("approval", "apr-race") == 1
    assert Repo.get_by!(Lease, lease_id: active.lease_id).status == "expired"

    reassign_results =
      1..4
      |> Task.async_stream(
        fn index ->
          OperationalLeases.reassign("approval", "apr-race", "reassign-#{index}", ttl_seconds: 60)
        end,
        max_concurrency: 4,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.any?(reassign_results, &match?({:ok, %Lease{}}, &1))
    assert active_lease_count("approval", "apr-race") == 1

    stale_output =
      capture_io(fn ->
        assert :ok = CLI.run(["queue", "ls", "--kind", "lease", "--freshness", "stale"])
      end)

    assert stale_output =~ "stale_lease"
  end

  test "queue and timeline diagnostics explain stale evidence and failed execution chains" do
    insert_snapshot!("ws-stale",
      status: "healthy",
      db_isolation: "local",
      observed_at: DateTime.add(DateTime.utc_now(), -1_800, :second)
    )

    insert_snapshot!("ws-fail", status: "blocked", db_isolation: "local")
    insert_approval!("apr-fail", workspace_id: "ws-fail", kind: "failed_run", command_id: "test")

    assert {:ok, proposed} = SafeActions.propose("apr-fail")

    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: "safe-token")

    Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-fail/runs", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, Jason.encode!(%{unexpected: "shape"}))
    end)

    assert {:error, {:malformed_devide_response, :missing_run_id}} =
             SafeActions.execute(proposed.action.action_id, confirm: true, client: client)

    queue_output =
      capture_io(fn ->
        assert :ok = CLI.run(["queue", "ls", "--sort", "urgency"])
      end)

    assert queue_output =~ "stale_evidence"
    assert queue_output =~ "malformed_response"

    timeline_output =
      capture_io(fn ->
        assert :ok = CLI.run(["timeline", "action", proposed.action.action_id])
      end)

    assert timeline_output =~ "safe_action.execute_denied"
    assert timeline_output =~ "outcome=malformed_response"
    assert timeline_output =~ "next=jx actions show #{proposed.action.action_id}"
  end

  defp insert_snapshot!(workspace_id, opts) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
    status = Keyword.fetch!(opts, :status)
    db_isolation = Keyword.fetch!(opts, :db_isolation)

    snapshot = %{
      id: workspace_id,
      name: "Workspace #{workspace_id}",
      status: status,
      lifecycle_status: "running",
      mode: "review",
      db_isolation: db_isolation,
      active_run: nil,
      latest_runs: [%{command_id: "test", status: "failed"}],
      proposal_risks: [],
      recent_blocks: [],
      attention_flags: []
    }

    %WorkspaceSnapshot{}
    |> WorkspaceSnapshot.changeset(%{
      workspace_id: workspace_id,
      name: "Workspace #{workspace_id}",
      lifecycle_status: "running",
      status: status,
      mode: "review",
      db_isolation: db_isolation,
      attention_flags: "[]",
      snapshot: Jason.encode!(snapshot),
      fingerprint: "fp-#{workspace_id}-#{System.unique_integer([:positive])}",
      source_url: "http://devide.local",
      last_observed_at: observed_at,
      last_changed_at: observed_at
    })
    |> Repo.insert!()
  end

  defp insert_approval!(approval_id, opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    kind = Keyword.fetch!(opts, :kind)
    command_id = Keyword.fetch!(opts, :command_id)

    %Approval{}
    |> Approval.changeset(%{
      approval_id: approval_id,
      source: "devide",
      workspace_id: workspace_id,
      kind: kind,
      severity: "warning",
      target_ref: command_id,
      summary: "DevIDE workspace #{workspace_id} has #{command_id} #{kind}",
      status: "open",
      metadata:
        Jason.encode!(%{
          "run" => %{
            "id" => "run-#{command_id}",
            "command_id" => command_id,
            "status" => "failed"
          }
        }),
      dedupe_key: "dedupe-#{approval_id}"
    })
    |> Repo.insert!()
  end

  defp insert_raw_operational_event!(attrs) do
    now = DateTime.utc_now()

    defaults = %{
      event_id: "ope-#{System.unique_integer([:positive])}",
      correlation_id: "corr-raw",
      source: "test",
      kind: "test.raw",
      entity_type: "workspace",
      entity_id: "raw",
      workspace_id: "",
      approval_id: "",
      action_id: "",
      lease_id: "",
      owner: "",
      severity: "info",
      summary: "raw event",
      payload: "{}",
      caused_by_event_id: "",
      inserted_at: now
    }

    {1, _rows} = Repo.insert_all(OperationalEvent, [Map.merge(defaults, attrs)])
  end

  defp active_lease_count(resource_type, resource_id) do
    Lease
    |> where(
      [lease],
      lease.resource_type == ^resource_type and lease.resource_id == ^resource_id and
        lease.status == "active"
    )
    |> Repo.aggregate(:count)
  end

  defp cleanup_state do
    Repo.delete_all(OperationalEvent)
    Repo.delete_all(Lease)
    Repo.delete_all(ExecutionEvent)
    Repo.delete_all(OrchestrationAction)
    Repo.delete_all(Approval)
    Repo.delete_all(Notification)
    Repo.delete_all(MonitorEvent)
    Repo.delete_all(WorkspaceSnapshot)
  end
end
