defmodule JX.CLI.OrchestrateTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Orchestrate

  defmodule FakeWorkspace do
    def orchestrate(opts) do
      send(self(), {:orchestrate, opts})
      {:ok, report(opts)}
    end

    def report(opts) do
      %{
        generated_at: "2026-05-12T00:00:00Z",
        consumer: opts[:consumer] || "orchestrator",
        mode: if(opts[:execute], do: "execute", else: "dry-run"),
        scan: scan(),
        inbox: %{
          cursor: %{consumer: "orchestrator", source: "test", last_event_id: 3},
          latest_event_id: 4,
          unread_total: 1,
          matching_unread_total: 1,
          returned: 1,
          events: [event()]
        },
        decisions: [
          %{
            id: "rec-1",
            status: "planned",
            safety: "safe",
            action: "prompt",
            ref: "ref-1",
            state: "active",
            prompt_status: "ready",
            event_ids: [4],
            reason: "ready to continue",
            message: "continue"
          }
        ],
        action_queue: nil,
        execution: %{mode: "dry-run"},
        heartbeat: nil,
        cursor: nil,
        errors: []
      }
    end

    defp scan do
      %{
        generated_at: "2026-05-12T00:00:00Z",
        observed: true,
        observation_refresh: %{saved: 1},
        sessions_total: 1,
        events_saved: 1,
        events: [event()],
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
    def orchestrate(opts) do
      send(self(), {:orchestrate, opts})
      {:ok, build_report(opts)}
    end

    defp build_report(opts) do
      %{
        generated_at: "2026-05-12T00:00:00Z",
        consumer: opts[:consumer] || "orchestrator",
        mode: if(opts[:execute], do: "execute", else: "dry-run"),
        scan: %{
          generated_at: "2026-05-12T00:00:00Z",
          observed: true,
          observation_refresh: %{saved: 1},
          sessions_total: 1,
          events_saved: 1,
          events: [event()],
          queues_total: 0,
          queues: [],
          watches_total: 1,
          watch_updates: [
            %{
              watch: session_watch(),
              previous_status: "idle",
              status: "active",
              changed?: true,
              profile_action: watch_action(),
              summary: "watch changed",
              ref: "ref-1"
            },
            %{
              watch: session_watch(),
              previous_status: "idle",
              status: "active",
              changed?: false,
              profile_action: nil,
              summary: "no change",
              ref: "ref-2"
            }
          ],
          watch_actions_total: 1,
          watch_actions: [watch_action()],
          ci_watches_total: 1,
          ci_watch_updates: [
            %{
              watch: ci_watch(),
              previous_status: "pending",
              status: "pass",
              changed?: true,
              profile_action: nil,
              summary: "CI passed",
              ref: "ref-1",
              digest: "abc123"
            }
          ],
          wake_triggers_total: 2,
          wake_notifications_saved: 0,
          wake_triggers: [
            %{
              status: "done",
              result: "ok",
              trigger: wake_trigger(),
              wake: nil,
              errors: []
            },
            %{
              status: "done",
              result: "ok",
              trigger: wake_trigger(),
              wake: %{
                wake_id: "wake-1",
                events: [event()],
                notifications: %{
                  notifications: [],
                  saved: 0,
                  errors: []
                }
              },
              errors: []
            }
          ],
          call_handoffs_total: 1,
          call_handoffs: [
            %{
              handoff_id: "h1",
              surface: "chat",
              status: "open",
              project: "p1",
              ref: "ref-1",
              title: "title",
              summary: "summary",
              operator_input: "input",
              decisions: "[{\"id\":\"d1\"}]",
              follow_ups: "[\"f1\"]",
              brief_snapshot: "{\"key\":\"val\"}",
              payload: "{\"data\":\"val\"}",
              closed_at: nil,
              inserted_at: "2026-05-12T00:00:00Z",
              updated_at: "2026-05-12T00:00:00Z"
            }
          ],
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
              source_event_id: 1,
              kind: "test",
              severity: "notice",
              status: "unread",
              ref: "ref-1",
              project: "p1",
              summary: "summary",
              payload:
                Jason.encode!(%{
                  "capture" => %{
                    "output" => "secret data here",
                    "summary" => "captured successfully"
                  }
                }),
              acknowledged_at: nil,
              inserted_at: "2026-05-12T00:00:00Z",
              updated_at: "2026-05-12T00:00:00Z"
            }
          ],
          profiles_total: 1,
          profiles: [],
          errors: []
        },
        inbox: %{
          cursor: %{consumer: "orchestrator", source: "test", last_event_id: 3},
          latest_event_id: 4,
          unread_total: 1,
          matching_unread_total: 1,
          returned: 1,
          events: [event()]
        },
        decisions: [
          %{
            id: "rec-1",
            status: "planned",
            safety: "safe",
            action: "prompt",
            ref: "ref-1",
            state: "active",
            prompt_status: "ready",
            event_ids: [4],
            reason: "ready to continue",
            message: "continue"
          }
        ],
        action_queue: nil,
        execution: %{mode: "dry-run"},
        heartbeat: nil,
        cursor: nil,
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

    defp session_watch do
      %{
        watch_id: "w1",
        ref: "ref-1",
        status: "active",
        mode: "auto",
        project: "p1",
        session_type: "agent",
        session_kind: "codex",
        goal: "goal",
        success_pattern: "success",
        blocker_pattern: "blocker",
        prompt: "prompt",
        last_summary: "summary",
        result_summary: "result",
        last_observed_at: "2026-05-12T00:00:00Z",
        completed_at: nil,
        inserted_at: "2026-05-12T00:00:00Z",
        updated_at: "2026-05-12T00:00:00Z"
      }
    end

    defp ci_watch do
      %{
        watch_id: "cw1",
        repo: "repo",
        pr_number: 1,
        ref: "ref-1",
        project: "p1",
        status: "active",
        mode: "auto",
        goal: "goal",
        head_sha: "abc",
        last_head_sha: "def",
        success_prompt: "sp",
        failure_prompt: "fp",
        last_overall: "pass",
        last_summary: "summary",
        last_digest: "{\"key\":\"val\"}",
        last_checked_at: "2026-05-12T00:00:00Z",
        last_head_checked_at: "2026-05-12T00:00:00Z",
        completed_at: nil,
        inserted_at: "2026-05-12T00:00:00Z",
        updated_at: "2026-05-12T00:00:00Z"
      }
    end

    defp watch_action do
      %{
        watch_id: "w1",
        ref: "ref-1",
        action: "test",
        status: "done",
        result_summary: "ok"
      }
    end

    defp wake_trigger do
      %{
        trigger_id: "t1",
        name: "test",
        status: "active",
        message: "msg",
        project: "p1",
        ref: "ref-1",
        severity: "notice",
        schedule: "daily",
        every_seconds: 3600,
        next_run_at: "2026-05-12T00:00:00Z",
        last_run_at: "2026-05-12T00:00:00Z",
        run_count: 5,
        last_result: "ok",
        inserted_at: "2026-05-12T00:00:00Z",
        updated_at: "2026-05-12T00:00:00Z"
      }
    end
  end

  defmodule ConfigurableFakeWorkspace do
    def orchestrate(opts) do
      send(self(), {:orchestrate, opts})
      {:ok, build_report(opts)}
    end

    defp build_report(opts) do
      %{
        generated_at: "2026-05-12T00:00:00Z",
        consumer: opts[:consumer] || "orchestrator",
        mode: if(opts[:execute], do: "execute", else: "dry-run"),
        scan: %{
          generated_at: "2026-05-12T00:00:00Z",
          observed: true,
          observation_refresh: %{saved: 1},
          sessions_total: 1,
          events_saved: 1,
          events: [event()],
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
          profiles_total: 1,
          profiles: [],
          errors: []
        },
        inbox: %{
          cursor: %{consumer: "orchestrator", source: "test", last_event_id: 3},
          latest_event_id: 4,
          unread_total: 1,
          matching_unread_total: 1,
          returned: 1,
          events: [event()]
        },
        decisions: decisions_for(opts),
        action_queue: nil,
        execution: execution_for(opts),
        heartbeat: nil,
        cursor: cursor_for(opts),
        errors: errors_for(opts)
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

    defp decisions_for(opts) do
      if Keyword.get(opts, :consumer) == "empty-decisions" do
        []
      else
        [
          %{
            id: "rec-1",
            status: "planned",
            safety: "safe",
            action: "prompt",
            ref: "ref-1",
            state: "active",
            prompt_status: "ready",
            event_ids: [4],
            reason: "ready to continue",
            message: "continue"
          }
        ]
      end
    end

    defp execution_for(opts) do
      case Keyword.get(opts, :consumer) do
        "execution-test" ->
          %{
            mode: "execute",
            requested: "2",
            executed: [
              %{
                status: "ok",
                id: "exec-1",
                action: "test",
                safety: "safe",
                ref: "ref-1",
                target: "target-1",
                result_summary: "completed successfully"
              }
            ],
            skipped: [
              %{
                status: "skipped",
                id: "exec-2",
                action: "test2",
                safety: "unsafe",
                ref: "ref-2",
                reason: "safety check failed"
              }
            ]
          }

        "empty-execution" ->
          %{mode: "execute", requested: "0", executed: [], skipped: []}

        "capture-execution" ->
          %{
            mode: "execute",
            requested: "1",
            executed: [
              %{
                status: "ok",
                id: "e1",
                action: "test",
                safety: "safe",
                ref: "r1",
                target: "t1",
                capture: %{summary: "captured output"}
              }
            ],
            skipped: []
          }

        "error-execution" ->
          %{
            mode: "execute",
            requested: "1",
            executed: [
              %{
                status: "error",
                id: "e1",
                action: "test",
                safety: "safe",
                ref: "r1",
                target: "t1",
                error: "execution failed"
              }
            ],
            skipped: []
          }

        "reason-execution" ->
          %{
            mode: "execute",
            requested: "1",
            executed: [
              %{
                status: "skipped",
                id: "e1",
                action: "test",
                safety: "safe",
                ref: "r1",
                target: "t1",
                reason: "not ready"
              }
            ],
            skipped: []
          }

        "catchall-execution" ->
          %{
            mode: "execute",
            requested: "1",
            executed: [
              %{
                status: "ok",
                id: "e1",
                action: "test",
                safety: "safe",
                ref: "r1",
                target: "t1"
              }
            ],
            skipped: []
          }

        _ ->
          %{mode: "dry-run"}
      end
    end

    defp cursor_for(opts) do
      if Keyword.get(opts, :consumer) == "cursor-test" do
        %{
          consumer: "orchestrator",
          source: "test",
          last_event_id: 42,
          last_seen_at: "2026-05-12T00:00:00Z",
          updated_at: "2026-05-12T00:00:00Z"
        }
      else
        nil
      end
    end

    defp errors_for(opts) do
      if Keyword.get(opts, :consumer) == "errors-test" do
        [
          %{
            host: "localhost",
            transport: "ssh",
            subsystem: "tmux",
            error: "connection failed"
          }
        ]
      else
        []
      end
    end
  end

  test "step parses orchestration options and renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   [
                     "step",
                     "--consumer",
                     "operator",
                     "--host",
                     "local",
                     "--type",
                     "agent",
                     "--work-state",
                     "running",
                     "--control",
                     "managed",
                     "--prompt-status",
                     "ready",
                     "--no-observe",
                     "--lines",
                     "12",
                     "--scan-limit",
                     "9",
                     "--queue-limit",
                     "4",
                     "--event-limit",
                     "3",
                     "--decision-limit",
                     "2",
                     "--min-observe-age-seconds",
                     "0",
                     "--execute",
                     "--ack",
                     "--auto-plan",
                     "--no-enter",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:orchestrate, opts}
    assert opts[:consumer] == "operator"
    assert opts[:host_name] == "local"
    assert opts[:type] == "agent"
    assert opts[:work_state] == "running"
    assert opts[:control_mode] == "managed"
    assert opts[:prompt_status] == "ready"
    assert opts[:observe] == false
    assert opts[:lines] == 12
    assert opts[:limit] == 9
    assert opts[:queue_limit] == 4
    assert opts[:event_limit] == 3
    assert opts[:decision_limit] == 2
    assert opts[:min_observe_age_seconds] == 0
    assert opts[:execute] == true
    assert opts[:ack] == true
    assert opts[:auto_plan] == true
    assert opts[:enter] == false

    assert %{"consumer" => "operator", "scan" => %{"sessions_total" => 1}} =
             Jason.decode!(output)
  end

  test "step renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   [
                     "step",
                     "--consumer",
                     "operator",
                     "--no-observe"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:orchestrate, opts}
    assert opts[:consumer] == "operator"
    assert opts[:observe] == false
    assert output =~ "consumer operator"
    assert output =~ "mode dry-run"
    assert output =~ "decisions"
    assert output =~ "execution: dry-run"
  end

  test "run honors bounded iterations" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(["run", "--iterations", "2", "--interval-ms", "1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:orchestrate, _opts}
    assert_received {:orchestrate, _opts}
    assert output =~ "orchestrate iteration 1"
    assert output =~ "orchestrate iteration 2"
    assert output =~ "decisions"
    assert output =~ "execution: dry-run"
  end

  test "run renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["run", "--iterations", "2", "--interval-ms", "1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:orchestrate, _opts}
    assert_received {:orchestrate, _opts}

    parts = String.split(output, ~r/orchestrate iteration \d+\n/, trim: true)
    assert length(parts) == 2

    Enum.each(parts, fn part ->
      decoded = Jason.decode!(part)
      assert is_map(decoded)
      assert decoded["consumer"] == "orchestrator"
      assert decoded["mode"] == "dry-run"
      assert decoded["scan"]["sessions_total"] == 1
    end)
  end

  test "invalid numeric options are rejected before starting the app" do
    assert {:error, message} =
             Orchestrate.run(["step", "--interval-ms", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "interval-ms must be a positive integer"
    refute_received :started
    refute_received :orchestrate
  end

  test "start renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["start", "--iterations", "1", "--interval-ms", "1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:orchestrate, _opts}
    assert output =~ "orchestrate iteration 1"
    assert output =~ "consumer orchestrator"
    assert output =~ "mode dry-run"
  end

  test "start renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["start", "--iterations", "1", "--interval-ms", "1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:orchestrate, _opts}

    parts = String.split(output, ~r/orchestrate iteration \d+\n/, trim: true)
    assert length(parts) == 1
    decoded = Jason.decode!(hd(parts))
    assert decoded["consumer"] == "orchestrator"
    assert decoded["mode"] == "dry-run"
  end

  test "step renders json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["step", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:orchestrate, _opts}
    decoded = Jason.decode!(output)
    assert decoded["consumer"] == "orchestrator"
    assert decoded["mode"] == "dry-run"
    assert decoded["scan"]["sessions_total"] == 1
  end

  test "missing command returns usage error" do
    assert {:error, message} = Orchestrate.run([], [])
    assert message =~ "usage:"
  end

  test "invalid command returns usage error" do
    assert {:error, message} = Orchestrate.run(["invalid"], [])
    assert message =~ "usage:"
  end

  test "missing start_app callback returns error" do
    assert {:error, :missing_start_app_callback} = Orchestrate.run(["step"], [])
  end

  test "invalid type is rejected" do
    assert {:error, message} =
             Orchestrate.run(["step", "--type", "invalid"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported session type"
    refute_received :started
  end

  test "invalid work state is rejected" do
    assert {:error, message} =
             Orchestrate.run(["step", "--work-state", "invalid"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported work state"
    refute_received :started
  end

  test "invalid control is rejected" do
    assert {:error, message} =
             Orchestrate.run(["step", "--control", "invalid"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported session control mode"
    refute_received :started
  end

  test "invalid prompt status is rejected" do
    assert {:error, message} =
             Orchestrate.run(["step", "--prompt-status", "invalid"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported prompt status"
    refute_received :started
  end

  test "negative lines is rejected" do
    assert {:error, message} =
             Orchestrate.run(["step", "--lines", "-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "lines must be a positive integer"
    refute_received :started
  end

  test "zero scan-limit is rejected" do
    assert {:error, message} =
             Orchestrate.run(["step", "--scan-limit", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "scan-limit must be a positive integer"
    refute_received :started
  end

  test "zero queue-limit is rejected" do
    assert {:error, message} =
             Orchestrate.run(["step", "--queue-limit", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "queue-limit must be a positive integer"
    refute_received :started
  end

  test "zero event-limit is rejected" do
    assert {:error, message} =
             Orchestrate.run(["step", "--event-limit", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "event-limit must be a positive integer"
    refute_received :started
  end

  test "zero decision-limit is rejected" do
    assert {:error, message} =
             Orchestrate.run(["step", "--decision-limit", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "decision-limit must be a positive integer"
    refute_received :started
  end

  test "negative min-observe-age-seconds is rejected" do
    assert {:error, message} =
             Orchestrate.run(["step", "--min-observe-age-seconds", "-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "min-observe-age-seconds must be a non-negative integer"
    refute_received :started
  end

  test "negative iterations is rejected" do
    assert {:error, message} =
             Orchestrate.run(["step", "--iterations", "-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "iterations must be a non-negative integer"
    refute_received :started
  end

  test "step with cursor prints cursor table" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["step", "--consumer", "cursor-test"],
                   start_app: start_app_callback(),
                   workspace: ConfigurableFakeWorkspace
                 )
      end)

    assert output =~ "CURSOR"
    assert output =~ "last_event_id"
    assert output =~ "42"
  end

  test "step with cursor renders json cursor" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["step", "--consumer", "cursor-test", "--json"],
                   start_app: start_app_callback(),
                   workspace: ConfigurableFakeWorkspace
                 )
      end)

    decoded = Jason.decode!(output)
    assert decoded["cursor"]["last_event_id"] == 42
    assert decoded["cursor"]["consumer"] == "orchestrator"
  end

  test "step with errors prints error table" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["step", "--consumer", "errors-test"],
                   start_app: start_app_callback(),
                   workspace: ConfigurableFakeWorkspace
                 )
      end)

    assert output =~ "HOST"
    assert output =~ "localhost"
    assert output =~ "connection failed"
  end

  test "step with errors renders json errors" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["step", "--consumer", "errors-test", "--json"],
                   start_app: start_app_callback(),
                   workspace: ConfigurableFakeWorkspace
                 )
      end)

    decoded = Jason.decode!(output)
    assert length(decoded["errors"]) == 1
    assert hd(decoded["errors"])["host"] == "localhost"
    assert hd(decoded["errors"])["error"] == "connection failed"
  end

  test "step with execution results prints execution table" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["step", "--consumer", "execution-test"],
                   start_app: start_app_callback(),
                   workspace: ConfigurableFakeWorkspace
                 )
      end)

    assert output =~ "execution 2"
    assert output =~ "completed successfully"
    assert output =~ "safety check failed"
    assert output =~ "ok"
    assert output =~ "skipped"
  end

  test "step with execution results renders json execution" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["step", "--consumer", "execution-test", "--json"],
                   start_app: start_app_callback(),
                   workspace: ConfigurableFakeWorkspace
                 )
      end)

    decoded = Jason.decode!(output)
    assert decoded["execution"]["mode"] == "execute"
    assert decoded["execution"]["requested"] == "2"
    assert length(decoded["execution"]["executed"]) == 1
    assert hd(decoded["execution"]["executed"])["status"] == "ok"
  end

  test "step with empty decisions prints none" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["step", "--consumer", "empty-decisions"],
                   start_app: start_app_callback(),
                   workspace: ConfigurableFakeWorkspace
                 )
      end)

    assert output =~ "decisions: none"
  end

  test "step with empty execution prints no matching actions" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["step", "--consumer", "empty-execution"],
                   start_app: start_app_callback(),
                   workspace: ConfigurableFakeWorkspace
                 )
      end)

    assert output =~ "execution 0"
    assert output =~ "no matching actions"
  end

  test "step with capture result prints capture summary" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["step", "--consumer", "capture-execution"],
                   start_app: start_app_callback(),
                   workspace: ConfigurableFakeWorkspace
                 )
      end)

    assert output =~ "captured output"
  end

  test "step with error result prints error" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["step", "--consumer", "error-execution"],
                   start_app: start_app_callback(),
                   workspace: ConfigurableFakeWorkspace
                 )
      end)

    assert output =~ "execution failed"
  end

  test "step with reason result prints reason" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["step", "--consumer", "reason-execution"],
                   start_app: start_app_callback(),
                   workspace: ConfigurableFakeWorkspace
                 )
      end)

    assert output =~ "not ready"
  end

  test "step with catchall result prints empty result" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["step", "--consumer", "catchall-execution"],
                   start_app: start_app_callback(),
                   workspace: ConfigurableFakeWorkspace
                 )
      end)

    assert output =~ "ok"
  end

  test "step with comprehensive scan renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Orchestrate.run(
                   ["step", "--json"],
                   start_app: start_app_callback(),
                   workspace: ComprehensiveFakeWorkspace
                 )
      end)

    decoded = Jason.decode!(output)
    assert decoded["consumer"] == "orchestrator"

    scan = decoded["scan"]
    assert length(scan["watch_updates"]) == 2
    assert length(scan["watch_actions"]) == 1
    assert length(scan["ci_watch_updates"]) == 1
    assert length(scan["wake_triggers"]) == 2
    assert length(scan["call_handoffs"]) == 1
    assert length(scan["notifications"]) == 1

    # Verify maybe_json_watch_action with nil
    ci_update = hd(scan["ci_watch_updates"])
    assert is_nil(ci_update["profile_action"])

    # Verify maybe_json_wake_result with nil and with data
    runs = scan["wake_triggers"]
    assert is_nil(hd(runs)["wake"])
    refute is_nil(hd(tl(runs))["wake"])

    # Verify decode_json_text and json_call_handoff
    handoff = hd(scan["call_handoffs"])
    assert handoff["decisions"] == [%{"id" => "d1"}]
    assert handoff["follow_ups"] == ["f1"]
    assert handoff["brief_snapshot"] == %{"key" => "val"}
    assert handoff["payload"] == %{"data" => "val"}

    # Verify CI watch decode_json_text for last_digest
    ci_watch = hd(scan["ci_watch_updates"])["watch"]
    assert ci_watch["last_digest"] == %{"key" => "val"}

    # Verify redact_operation_snapshot through notification payload
    notification = hd(scan["notifications"])
    payload = notification["payload"]
    assert payload["capture"]["output_redacted"] == true
    assert payload["capture"]["output_bytes"] == 16
  end

  test "infinite loop prints generic error and continues" do
    me = self()
    call_count = :atomics.new(1, [])

    output =
      capture_io(:stderr, fn ->
        pid =
          spawn(fn ->
            Process.put(:jx_cli_orchestrate_fun, fn opts ->
              case :atomics.add_get(call_count, 1, 1) do
                1 ->
                  {:error, "simulated failure"}

                _ ->
                  send(me, :continued)
                  {:ok, FakeWorkspace.report(opts)}
              end
            end)

            Orchestrate.run(
              ["start", "--interval-ms", "1"],
              start_app: start_app_callback(),
              workspace: FakeWorkspace
            )
          end)

        assert_receive :continued, 2000
        Process.exit(pid, :kill)
      end)

    assert output =~ "orchestrate iteration failed: simulated failure"
  end

  test "infinite loop prints exception error and continues" do
    me = self()
    call_count = :atomics.new(1, [])

    output =
      capture_io(:stderr, fn ->
        pid =
          spawn(fn ->
            Process.put(:jx_cli_orchestrate_fun, fn opts ->
              case :atomics.add_get(call_count, 1, 1) do
                1 ->
                  raise "simulated exception"

                _ ->
                  send(me, :continued)
                  {:ok, FakeWorkspace.report(opts)}
              end
            end)

            Orchestrate.run(
              ["start", "--interval-ms", "1"],
              start_app: start_app_callback(),
              workspace: FakeWorkspace
            )
          end)

        assert_receive :continued, 2000
        Process.exit(pid, :kill)
      end)

    assert output =~ "simulated exception"
  end

  test "infinite loop prints json error and continues" do
    me = self()
    call_count = :atomics.new(1, [])

    output =
      capture_io(fn ->
        pid =
          spawn(fn ->
            Process.put(:jx_cli_orchestrate_fun, fn opts ->
              case :atomics.add_get(call_count, 1, 1) do
                1 ->
                  {:error, "simulated failure"}

                _ ->
                  send(me, :continued)
                  {:ok, FakeWorkspace.report(opts)}
              end
            end)

            Orchestrate.run(
              ["start", "--interval-ms", "1", "--json"],
              start_app: start_app_callback(),
              workspace: FakeWorkspace
            )
          end)

        assert_receive :continued, 2000
        Process.exit(pid, :kill)
      end)

    parts = String.split(output, ~r/orchestrate iteration \d+\n/, trim: true)
    assert length(parts) >= 1
    decoded = Jason.decode!(hd(parts))
    assert decoded["error"] == "simulated failure"
  end

  test "bounded loop returns error on exception" do
    Process.put(:jx_cli_orchestrate_fun, fn _opts ->
      raise "simulated exception"
    end)

    assert {:error,
            {:exception, %RuntimeError{message: "simulated exception"}, _stacktrace}} =
             Orchestrate.run(
               ["run", "--iterations", "1", "--interval-ms", "1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )
  end

  test "bounded loop returns error on throw" do
    Process.put(:jx_cli_orchestrate_fun, fn _opts ->
      throw(:simulated_throw)
    end)

    assert {:error, {:caught, :throw, :simulated_throw, _stacktrace}} =
             Orchestrate.run(
               ["run", "--iterations", "1", "--interval-ms", "1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
