defmodule JX.CLI.MonitorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Monitor

  defmodule FakeWorkspace do
    def monitor_scan(opts) do
      send(self(), {:monitor_scan, opts})
      {:ok, scan()}
    end

    def monitor_event_status(opts) do
      send(self(), {:monitor_event_status, opts})

      if opts[:consumer] == "empty" do
        %{
          consumer: "empty",
          cursor: %{
            consumer: "empty",
            source: "test",
            last_event_id: 0,
            last_seen_at: nil,
            updated_at: nil
          },
          latest_event_id: 0,
          unread_total: 0,
          caught_up: true,
          latest_event: nil
        }
      else
        %{
          consumer: opts[:consumer] || "default",
          cursor: %{
            consumer: opts[:consumer] || "default",
            source: "test",
            last_event_id: 3,
            last_seen_at: "2026-05-12T00:00:00Z",
            updated_at: "2026-05-12T00:00:01Z"
          },
          latest_event_id: 4,
          unread_total: 1,
          caught_up: false,
          latest_event: event()
        }
      end
    end

    defp scan do
      %{
        generated_at: "2026-05-12T00:00:00Z",
        observed: true,
        observation_refresh: %{saved: 1},
        sessions_total: 1,
        events_saved: 1,
        events: [event()],
        queues_total: 1,
        queues: [
          %{
            action: "prompt",
            total: 1,
            by_priority: %{"high" => 1},
            by_safety: %{"safe" => 1},
            by_control: %{"managed" => 1},
            items: [%{ref: "ref-1", task: "continue", current_path: "/tmp/work", pane: "p1"}]
          }
        ],
        watches_total: 0,
        watch_updates: [],
        watch_actions_total: 0,
        watch_actions: [],
        ci_watches_total: 0,
        ci_watch_updates: [],
        wake_triggers_total: 0,
        wake_notifications_saved: 0,
        wake_triggers: [],
        call_handoffs_total: 0,
        call_handoffs: [],
        delegations_total: 0,
        delegations: [],
        delegation_reviews_total: 0,
        delegation_reviews: [],
        delegation_preflight: %{},
        delegation_timing: %{active: %{long_running: 0}},
        notifications_saved: 0,
        notifications: [],
        profiles_total: 1,
        profiles: [],
        errors: []
      }
    end

    defp event do
      %{
        id: 4,
        event_id: "evt-4",
        kind: "session.changed",
        severity: "notice",
        ref: "ref-1",
        project: "saysure",
        session_type: "agent",
        session_kind: "codex",
        control_mode: "managed",
        work_state: "running",
        action: "observe",
        summary: "session changed",
        fingerprint: "fingerprint",
        payload: "{}",
        inserted_at: "2026-05-12T00:00:00Z"
      }
    end
  end

  defmodule ComprehensiveFakeWorkspace do
    def monitor_scan(_opts) do
      {:ok, scan()}
    end

    def monitor_event_status(opts) do
      %{
        consumer: opts[:consumer] || "default",
        cursor: %{
          consumer: opts[:consumer] || "default",
          source: "test",
          last_event_id: 3,
          last_seen_at: ~U[2026-05-12 00:00:00Z],
          updated_at: ~U[2026-05-12 00:00:01Z]
        },
        latest_event_id: 4,
        unread_total: 1,
        caught_up: false,
        latest_event: event()
      }
    end

    defp scan do
      %{
        generated_at: ~U[2026-05-12 00:00:00Z],
        observed: true,
        observation_refresh: %{
          saved: 1,
          struct_test: ~U[2026-05-12 00:00:00Z],
          map_test: %{nested: 2},
          bool_test: true,
          bool_false_test: false,
          string_test: "hello",
          nil_test: nil,
          catch_all_test: [1, 2, 3]
        },
        sessions_total: 2,
        events_saved: 2,
        events: [
          event(),
          event(%{id: 5, event_id: "evt-5", kind: "session.ready", summary: "another event"})
        ],
        queues_total: 1,
        queues: [
          %{
            action: "prompt",
            total: 1,
            by_priority: %{"high" => 1},
            by_safety: %{"safe" => 1},
            by_control: %{"managed" => 1},
            items: [%{ref: "ref-1", task: "continue", current_path: "/tmp/work", pane: "p1"}]
          }
        ],
        watches_total: 1,
        watch_updates: [
          %{
            watch: %{
              watch_id: "w1",
              ref: "ref-1",
              status: "active",
              mode: "notify",
              project: "saysure",
              session_type: "agent",
              session_kind: "codex",
              goal:
                "watch goal that is very long and should be truncated because it exceeds forty four characters",
              success_pattern: "ok",
              blocker_pattern: "block",
              prompt: "prompt",
              last_summary: "summary",
              result_summary: "result",
              last_observed_at: ~U[2026-05-12 00:00:00Z],
              completed_at: nil,
              inserted_at: ~U[2026-05-12 00:00:00Z],
              updated_at: ~U[2026-05-12 00:00:00Z]
            },
            previous_status: "idle",
            status: "running",
            changed?: true,
            profile_action: %{
              watch_id: "w1",
              ref: "ref-1",
              action: "prompt",
              status: "active",
              prompt_status: "ready",
              reason: "profile action reason",
              result_summary: "profile action result"
            },
            summary:
              "watch updated with a very long summary that should definitely be truncated because it exceeds seventy two characters limit"
          }
        ],
        watch_actions_total: 1,
        watch_actions: [
          %{
            watch_id: "w1",
            ref: "ref-1",
            action: "prompt",
            status: "active",
            prompt_status: "ready",
            reason: "reason text",
            result_summary: "result summary"
          }
        ],
        ci_watches_total: 1,
        ci_watch_updates: [
          %{
            watch: %{
              watch_id: "cw1",
              repo: "saysure",
              pr_number: 42,
              ref: "ref-1",
              project: "saysure",
              status: "active",
              mode: "notify",
              goal: "ci goal",
              head_sha: "abc",
              last_head_sha: "def",
              success_prompt: "success",
              failure_prompt: "failure",
              last_overall: "pass",
              last_summary: "summary",
              last_digest: "{}",
              last_checked_at: ~U[2026-05-12 00:00:00Z],
              last_head_checked_at: ~U[2026-05-12 00:00:00Z],
              completed_at: nil,
              inserted_at: ~U[2026-05-12 00:00:00Z],
              updated_at: ~U[2026-05-12 00:00:00Z]
            },
            previous_status: "pending",
            status: "passed",
            changed?: true,
            profile_action: nil,
            summary: "ci watch updated",
            digest: "digest"
          }
        ],
        wake_triggers_total: 1,
        wake_notifications_saved: 1,
        wake_triggers: [
          %{
            status: "completed",
            result: "ok",
            trigger: %{
              trigger_id: "t1",
              name: "trigger-1",
              status: "active",
              message: "msg",
              project: "saysure",
              ref: "ref-1",
              severity: "notice",
              schedule: "daily",
              every_seconds: 86400,
              next_run_at: ~U[2026-05-13 00:00:00Z],
              last_run_at: ~U[2026-05-12 00:00:00Z],
              run_count: 1,
              last_result: "ok",
              inserted_at: ~U[2026-05-12 00:00:00Z],
              updated_at: ~U[2026-05-12 00:00:00Z]
            },
            wake: %{
              wake_id: "wake-1",
              events: [event()],
              notifications: %{
                notifications: [notification()],
                saved: 1,
                errors: []
              }
            },
            errors: []
          },
          %{
            status: "failed",
            result: "error",
            trigger: %{
              trigger_id: "t2",
              name: "trigger-2",
              status: "active",
              message: "msg",
              project: "saysure",
              ref: "ref-2",
              severity: "warning",
              schedule: "hourly",
              every_seconds: 3600,
              next_run_at: nil,
              last_run_at: nil,
              run_count: 0,
              last_result: nil,
              inserted_at: ~N[2026-05-12 00:00:00],
              updated_at: ~N[2026-05-12 00:00:00]
            },
            wake: nil,
            errors: [%{error: :atom_error}]
          }
        ],
        call_handoffs_total: 1,
        call_handoffs: [
          %{
            handoff_id: "h1",
            surface: "web",
            status: "open",
            project: "saysure",
            ref: "ref-1",
            title: "title",
            summary: "summary",
            operator_input: "input",
            decisions: "not json",
            follow_ups: nil,
            brief_snapshot: "",
            payload: ~s({"payload":true}),
            closed_at: nil,
            inserted_at: ~U[2026-05-12 00:00:00Z],
            updated_at: ~U[2026-05-12 00:00:00Z]
          }
        ],
        delegations_total: 1,
        delegations: [
          %JX.Delegations.Delegation{
            delegation_id: "d1",
            status: "completed",
            priority: 1,
            project: "saysure",
            ref: "ref-1",
            source: "test",
            owner: "test",
            agent_kind: "worker",
            title: "Test Delegation",
            brief: "Brief",
            context: ~s(["ctx"]),
            constraints: ~s(["c1"]),
            acceptance: ~s(["a1"]),
            verification: ~s(["v1"]),
            write_paths: ~s(["wp"]),
            forbidden_paths: ~s(["fp"]),
            lint_warnings: ~s(["lw"]),
            evidence: ~s([{"status":"ok","file":"f"}]),
            residual_risks: ~s(["r1"]),
            artifacts: ~s(["art"]),
            integration_status: "pending",
            integration_summary: "summary",
            reviewed_by: "reviewer",
            payload: ~s({"ok":true})
          }
        ],
        delegation_reviews_total: 1,
        delegation_reviews: [%{review_id: "r1", status: "ok"}],
        delegation_preflight: %{conflicts_total: 0},
        delegation_timing: %{active: %{long_running: 1}},
        notifications_saved: 1,
        notifications: [notification()],
        profiles_total: 1,
        profiles: [%{ref: "ref-1", summary: "profile"}],
        errors: [
          %{
            host: "test-host",
            transport: "ssh",
            subsystem: "tmux",
            error: "test-error"
          }
        ]
      }
    end

    defp event(attrs \\ %{}) do
      %{
        id: Map.get(attrs, :id, 4),
        event_id: "evt-#{Map.get(attrs, :id, 4)}",
        kind: Map.get(attrs, :kind, "session.changed"),
        severity: "notice",
        ref: "ref-1",
        project: "saysure",
        session_type: "agent",
        session_kind: "codex",
        control_mode: "managed",
        work_state: "running",
        action: "observe",
        summary: Map.get(attrs, :summary, "session changed"),
        fingerprint: "fingerprint",
        payload: "{}",
        inserted_at: "2026-05-12T00:00:00Z"
      }
    end

    defp notification do
      %{
        notification_id: "n1",
        source_event_id: 4,
        kind: "alert",
        severity: "notice",
        status: "unread",
        ref: "ref-1",
        project: "saysure",
        summary: "notification summary",
        payload: ~s({"ok":true}),
        acknowledged_at: nil,
        inserted_at: "2026-05-12T00:00:00Z",
        updated_at: "2026-05-12T00:00:00Z"
      }
    end
  end

  defmodule ErrorFakeWorkspace do
    def monitor_scan(_opts) do
      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         observed: true,
         observation_refresh: %{saved: 1},
         sessions_total: 1,
         events_saved: 0,
         events: [],
         queues_total: 0,
         queues: [],
         watches_total: 0,
         watch_updates: [],
         watch_actions_total: 0,
         watch_actions: [],
         ci_watches_total: 0,
         ci_watch_updates: [],
         wake_triggers_total: 0,
         wake_notifications_saved: 0,
         wake_triggers: [],
         call_handoffs_total: 0,
         call_handoffs: [],
         delegations_total: 0,
         delegations: [],
         delegation_reviews_total: 0,
         delegation_reviews: [],
         delegation_preflight: %{},
         delegation_timing: %{active: %{long_running: 0}},
         notifications_saved: 0,
         notifications: [],
         profiles_total: 0,
         profiles: [],
         errors: [
           %{
             host: "test-host",
             transport: "ssh",
             subsystem: "tmux",
             error: "test-error"
           }
         ]
       }}
    end

    def monitor_event_status(opts) do
      %{
        consumer: opts[:consumer] || "default",
        cursor: %{},
        latest_event_id: 0,
        unread_total: 0,
        caught_up: true,
        latest_event: nil
      }
    end
  end

  defmodule EmptyQueueFakeWorkspace do
    def monitor_scan(_opts) do
      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         observed: true,
         observation_refresh: %{saved: 1},
         sessions_total: 1,
         events_saved: 0,
         events: [],
         queues_total: 1,
         queues: [
           %{
             action: "prompt",
             total: 0,
             by_priority: %{},
             by_safety: %{},
             by_control: %{},
             items: []
           }
         ],
         watches_total: 0,
         watch_updates: [],
         watch_actions_total: 0,
         watch_actions: [],
         ci_watches_total: 0,
         ci_watch_updates: [],
         wake_triggers_total: 0,
         wake_notifications_saved: 0,
         wake_triggers: [],
         call_handoffs_total: 0,
         call_handoffs: [],
         delegations_total: 0,
         delegations: [],
         delegation_reviews_total: 0,
         delegation_reviews: [],
         delegation_preflight: %{},
         delegation_timing: %{active: %{long_running: 0}},
         notifications_saved: 0,
         notifications: [],
         profiles_total: 0,
         profiles: [],
         errors: []
       }}
    end

    def monitor_event_status(opts) do
      %{
        consumer: opts[:consumer] || "default",
        cursor: %{},
        latest_event_id: 0,
        unread_total: 0,
        caught_up: true,
        latest_event: nil
      }
    end
  end

  defmodule BadPayloadFakeWorkspace do
    def monitor_scan(_opts) do
      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         observed: true,
         observation_refresh: %{saved: 1},
         sessions_total: 1,
         events_saved: 1,
         events: [
           %{
             id: 4,
             event_id: "evt-4",
             kind: "session.changed",
             severity: "notice",
             ref: "ref-1",
             project: "saysure",
             session_type: "agent",
             session_kind: "codex",
             control_mode: "managed",
             work_state: "running",
             action: "observe",
             summary: "session changed",
             fingerprint: "fingerprint",
             payload: "not json",
             inserted_at: "2026-05-12T00:00:00Z"
           }
         ],
         queues_total: 0,
         queues: [],
         watches_total: 0,
         watch_updates: [],
         watch_actions_total: 0,
         watch_actions: [],
         ci_watches_total: 0,
         ci_watch_updates: [],
         wake_triggers_total: 0,
         wake_notifications_saved: 0,
         wake_triggers: [],
         call_handoffs_total: 0,
         call_handoffs: [],
         delegations_total: 0,
         delegations: [],
         delegation_reviews_total: 0,
         delegation_reviews: [],
         delegation_preflight: %{},
         delegation_timing: %{active: %{long_running: 0}},
         notifications_saved: 0,
         notifications: [],
         profiles_total: 0,
         profiles: [],
         errors: []
       }}
    end

    def monitor_event_status(opts) do
      %{
        consumer: opts[:consumer] || "default",
        cursor: %{},
        latest_event_id: 0,
        unread_total: 0,
        caught_up: true,
        latest_event: nil
      }
    end
  end

  defmodule RedactedPayloadFakeWorkspace do
    def monitor_scan(_opts) do
      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         observed: true,
         observation_refresh: %{saved: 1},
         sessions_total: 1,
         events_saved: 0,
         events: [],
         queues_total: 0,
         queues: [],
         watches_total: 0,
         watch_updates: [],
         watch_actions_total: 0,
         watch_actions: [],
         ci_watches_total: 0,
         ci_watch_updates: [],
         wake_triggers_total: 0,
         wake_notifications_saved: 0,
         wake_triggers: [],
         call_handoffs_total: 0,
         call_handoffs: [],
         delegations_total: 0,
         delegations: [],
         delegation_reviews_total: 0,
         delegation_reviews: [],
         delegation_preflight: %{},
         delegation_timing: %{active: %{long_running: 0}},
         notifications_saved: 1,
         notifications: [
           %{
             notification_id: "n1",
             source_event_id: 4,
             kind: "alert",
             severity: "notice",
             status: "unread",
             ref: "ref-1",
             project: "saysure",
             summary: "notification with secret",
             payload: ~s({"capture":{"output":"secret data"}}),
             acknowledged_at: nil,
             inserted_at: "2026-05-12T00:00:00Z",
             updated_at: "2026-05-12T00:00:00Z"
           }
         ],
         profiles_total: 0,
         profiles: [],
         errors: []
       }}
    end

    def monitor_event_status(opts) do
      %{
        consumer: opts[:consumer] || "default",
        cursor: %{},
        latest_event_id: 0,
        unread_total: 0,
        caught_up: true,
        latest_event: nil
      }
    end
  end

  test "scan parses filters and renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(
                   [
                     "scan",
                     "--host",
                     "local",
                     "--type",
                     "agent",
                     "--work-state",
                     "running",
                     "--no-observe",
                     "--lines",
                     "12",
                     "--scan-limit",
                     "9",
                     "--queue-limit",
                     "4",
                     "--event-limit",
                     "3",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:monitor_scan, opts}
    assert opts[:host_name] == "local"
    assert opts[:type] == "agent"
    assert opts[:work_state] == "running"
    assert opts[:observe] == false
    assert opts[:lines] == 12
    assert opts[:limit] == 9
    assert opts[:queue_limit] == 4
    assert opts[:event_limit] == 3

    assert %{"sessions_total" => 1, "events" => [%{"event_id" => "evt-4"}]} =
             Jason.decode!(output)
  end

  test "run honors bounded iterations" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["run", "--iterations", "2", "--interval-ms", "1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:monitor_scan, _opts}
    assert_received {:monitor_scan, _opts}
    assert output =~ "monitor iteration 1"
    assert output =~ "monitor iteration 2"
  end

  test "run renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["run", "--iterations", "1", "--interval-ms", "1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:monitor_scan, _opts}

    assert %{"sessions_total" => 1, "events" => [%{"event_id" => "evt-4"}]} =
             Jason.decode!(output)
  end

  test "start renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["start", "--iterations", "1", "--interval-ms", "1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:monitor_scan, _opts}

    assert %{"sessions_total" => 1, "events" => [%{"event_id" => "evt-4"}]} =
             Jason.decode!(output)
  end

  test "status routes through monitor event status" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["status", "--consumer", "operator", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:monitor_event_status, [consumer: "operator"]}

    assert %{"consumer" => "operator", "latest_event" => %{"event_id" => "evt-4"}} =
             Jason.decode!(output)
  end

  test "invalid numeric options are rejected before starting the app" do
    assert {:error, message} =
             Monitor.run(["scan", "--event-limit", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "event-limit must be a positive integer"
    refute_received :started
    refute_received :monitor_scan
  end

  test "scan renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["scan"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "monitor"
    assert output =~ "sessions"
    assert output =~ "observation refresh"
    assert output =~ "new events"
    assert output =~ "queues"
  end

  test "start renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["start", "--iterations", "1", "--interval-ms", "1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "monitor iteration 1"
    assert output =~ "monitor"
    assert output =~ "sessions"
  end

  test "status renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["status", "--consumer", "operator"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "consumer"
    assert output =~ "operator"
    assert output =~ "last_event_id"
    assert output =~ "latest_event_id"
    assert output =~ "latest event"
    assert output =~ "session.changed"
  end

  test "status without latest_event renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["status", "--consumer", "empty"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "consumer"
    refute output =~ "latest event"
  end

  test "status without latest_event renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["status", "--consumer", "empty", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    decoded = Jason.decode!(output)
    assert decoded["consumer"] == "empty"
    assert decoded["latest_event"] == nil
  end

  test "invalid command returns usage error" do
    assert {:error, message} = Monitor.run(["invalid"], start_app: start_app_callback())
    assert message =~ "usage:"
    refute_received :started
  end

  test "missing start_app callback returns error" do
    assert {:error, :missing_start_app_callback} =
             Monitor.run(["scan"], workspace: FakeWorkspace)
  end

  test "extra positional args are rejected" do
    assert {:error, message} =
             Monitor.run(["scan", "extra-arg"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage:"
    refute_received :started
  end

  test "invalid option flags are rejected" do
    assert {:error, message} =
             Monitor.run(["scan", "--invalid-flag"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "invalid"
    refute_received :started
  end

  test "invalid type is rejected" do
    assert {:error, message} =
             Monitor.run(["scan", "--type", "bad"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported session type"
    refute_received :started
  end

  test "invalid work_state is rejected" do
    assert {:error, message} =
             Monitor.run(["scan", "--work-state", "bad"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported work state"
    refute_received :started
  end

  test "invalid control is rejected" do
    assert {:error, message} =
             Monitor.run(["scan", "--control", "bad"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported session control mode"
    refute_received :started
  end

  test "invalid prompt_status is rejected" do
    assert {:error, message} =
             Monitor.run(["scan", "--prompt-status", "bad"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported prompt status"
    refute_received :started
  end

  test "lines must be positive" do
    assert {:error, "lines must be a positive integer"} =
             Monitor.run(["scan", "--lines", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    refute_received :started
  end

  test "scan-limit must be positive" do
    assert {:error, "scan-limit must be a positive integer"} =
             Monitor.run(["scan", "--scan-limit", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    refute_received :started
  end

  test "queue-limit must be positive" do
    assert {:error, "queue-limit must be a positive integer"} =
             Monitor.run(["scan", "--queue-limit", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    refute_received :started
  end

  test "event-limit must be positive" do
    assert {:error, "event-limit must be a positive integer"} =
             Monitor.run(["scan", "--event-limit", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    refute_received :started
  end

  test "interval-ms must be positive" do
    assert {:error, "interval-ms must be a positive integer"} =
             Monitor.run(["scan", "--interval-ms", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    refute_received :started
  end

  test "iterations must be non-negative" do
    assert {:error, "iterations must be a non-negative integer"} =
             Monitor.run(["scan", "--iterations", "-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    refute_received :started
  end

  test "control uncontrolled is valid" do
    capture_io(fn ->
      assert :ok =
               Monitor.run(["scan", "--control", "uncontrolled", "--json"],
                 start_app: start_app_callback(),
                 workspace: FakeWorkspace
               )
    end)

    assert_received :started
  end

  test "scan with comprehensive data renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["scan", "--json"],
                   start_app: start_app_callback(),
                   workspace: ComprehensiveFakeWorkspace
                 )
      end)

    assert_received :started
    decoded = Jason.decode!(output)
    assert decoded["sessions_total"] == 2
    assert decoded["events"] |> length() == 2
    assert decoded["watch_updates"] |> length() == 1
    assert decoded["wake_triggers"] |> length() == 2
    assert get_in(decoded, ["wake_triggers", Access.at(1), "wake"]) == nil
    assert get_in(decoded, ["call_handoffs", Access.at(0), "decisions"]) == "not json"

    assert get_in(decoded, ["wake_triggers", Access.at(1), "errors", Access.at(0), "error"]) ==
             ":atom_error"
  end

  test "scan with comprehensive data renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["scan"],
                   start_app: start_app_callback(),
                   workspace: ComprehensiveFakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "monitor"
    assert output =~ "watch updates"
    assert output =~ "watch actions"
    assert output =~ "CI watch updates"
    assert output =~ "notifications"
    assert output =~ "test-host"
    assert output =~ "watch goal that is very long and should b..."
    assert output =~ "watch updated with a very long summary that should definitely be trun..."
  end

  test "scan with errors renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["scan"],
                   start_app: start_app_callback(),
                   workspace: ErrorFakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "test-host"
    assert output =~ "test-error"
  end

  test "scan with empty queue items renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["scan", "--json"],
                   start_app: start_app_callback(),
                   workspace: EmptyQueueFakeWorkspace
                 )
      end)

    assert_received :started
    decoded = Jason.decode!(output)
    assert decoded["queues"] |> length() == 1
  end

  test "scan with empty queue items renders text" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["scan"],
                   start_app: start_app_callback(),
                   workspace: EmptyQueueFakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "queues"
  end

  defmodule NonBinaryQueueFakeWorkspace do
    def monitor_scan(_opts) do
      {:ok,
       %{
         generated_at: "2026-05-12T00:00:00Z",
         observed: true,
         observation_refresh: %{saved: 1},
         sessions_total: 1,
         events_saved: 0,
         events: [],
         queues_total: 1,
         queues: [
           %{
             action: "prompt",
             total: 0,
             by_priority: %{},
             by_safety: %{},
             by_control: %{},
             items: [%{ref: "ref-1", task: 123, current_path: nil, pane: nil}]
           }
         ],
         watches_total: 0,
         watch_updates: [],
         watch_actions_total: 0,
         watch_actions: [],
         ci_watches_total: 0,
         ci_watch_updates: [],
         wake_triggers_total: 0,
         wake_notifications_saved: 0,
         wake_triggers: [],
         call_handoffs_total: 0,
         call_handoffs: [],
         delegations_total: 0,
         delegations: [],
         delegation_reviews_total: 0,
         delegation_reviews: [],
         delegation_preflight: %{},
         delegation_timing: %{active: %{long_running: 0}},
         notifications_saved: 0,
         notifications: [],
         profiles_total: 0,
         profiles: [],
         errors: []
       }}
    end

    def monitor_event_status(opts) do
      %{
        consumer: opts[:consumer] || "default",
        cursor: %{},
        latest_event_id: 0,
        unread_total: 0,
        caught_up: true,
        latest_event: nil
      }
    end
  end

  test "scan with non-binary queue items renders text" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["scan"],
                   start_app: start_app_callback(),
                   workspace: NonBinaryQueueFakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "queues"
  end

  test "scan with invalid json payload renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["scan", "--json"],
                   start_app: start_app_callback(),
                   workspace: BadPayloadFakeWorkspace
                 )
      end)

    assert_received :started
    decoded = Jason.decode!(output)
    assert get_in(decoded, ["events", Access.at(0), "payload"]) == "not json"
  end

  test "scan with redacted notification payload renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Monitor.run(["scan", "--json"],
                   start_app: start_app_callback(),
                   workspace: RedactedPayloadFakeWorkspace
                 )
      end)

    assert_received :started
    decoded = Jason.decode!(output)

    assert get_in(decoded, [
             "notifications",
             Access.at(0),
             "payload",
             "capture",
             "output_redacted"
           ]) == true
  end

  test "print_monitor_events with empty list prints no events" do
    output = capture_io(fn -> Monitor.print_monitor_events([], json: false) end)
    assert output =~ "no monitor events"
  end

  test "print_monitor_events with empty list prints json" do
    output = capture_io(fn -> Monitor.print_monitor_events([], json: true) end)
    assert Jason.decode!(output) == %{"events" => []}
  end

  test "print_monitor_events with events renders table" do
    output =
      capture_io(fn ->
        Monitor.print_monitor_events(
          [
            %{
              id: 1,
              event_id: "e1",
              kind: "k",
              severity: "notice",
              ref: "r",
              project: "p",
              work_state: "running",
              action: "a",
              summary: "summary",
              inserted_at: "2026-05-12T00:00:00Z"
            }
          ],
          json: false
        )
      end)

    assert output =~ "session.changed" or output =~ "ID"
  end

  test "print_monitor_events with events renders json" do
    output =
      capture_io(fn ->
        Monitor.print_monitor_events(
          [
            %{
              id: 1,
              event_id: "e1",
              kind: "k",
              severity: "notice",
              ref: "r",
              project: "p",
              work_state: "running",
              action: "a",
              summary: "summary",
              inserted_at: "2026-05-12T00:00:00Z",
              payload: "{}"
            }
          ],
          json: true
        )
      end)

    assert %{"events" => [%{"id" => 1}]} = Jason.decode!(output)
  end

  test "print_notifications with empty list prints no notifications" do
    output = capture_io(fn -> Monitor.print_notifications([], json: false) end)
    assert output =~ "no notifications"
  end

  test "print_notifications with empty list prints json" do
    output = capture_io(fn -> Monitor.print_notifications([], json: true) end)
    assert Jason.decode!(output) == %{"notifications" => []}
  end

  test "print_notifications with notifications renders table" do
    output =
      capture_io(fn ->
        Monitor.print_notifications(
          [
            %{
              notification_id: "n1",
              status: "unread",
              severity: "notice",
              ref: "r",
              project: "p",
              kind: "alert",
              summary: "summary",
              inserted_at: "2026-05-12T00:00:00Z"
            }
          ],
          json: false
        )
      end)

    assert output =~ "n1"
  end

  test "print_notifications with notifications renders json" do
    output =
      capture_io(fn ->
        Monitor.print_notifications(
          [
            %{
              notification_id: "n1",
              source_event_id: 1,
              status: "unread",
              severity: "notice",
              ref: "r",
              project: "p",
              kind: "alert",
              summary: "summary",
              payload: "{}",
              acknowledged_at: nil,
              inserted_at: "2026-05-12T00:00:00Z",
              updated_at: "2026-05-12T00:00:00Z"
            }
          ],
          json: true
        )
      end)

    assert %{"notifications" => [%{"notification_id" => "n1"}]} = Jason.decode!(output)
  end

  test "summary_value handles all types" do
    assert Monitor.summary_value(42) == "42"
    assert Monitor.summary_value(true) == "yes"
    assert Monitor.summary_value("hello") == "hello"
    assert Monitor.summary_value(~U[2026-05-12 00:00:00Z]) == "2026-05-12 00:00:00Z"
    assert Monitor.summary_value(nil) == ""
    assert Monitor.summary_value([1, 2]) == "[1, 2]"
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
