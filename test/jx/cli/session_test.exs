defmodule JX.CLI.SessionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Session

  defmodule FakeWorkspace do
    def capture_session(ref, opts) do
      send(self(), {:capture_session, ref, opts})
      {:ok, "recent pane output\n"}
    end

    def attach_session(ref) do
      send(self(), {:attach_session, ref})
      :ok
    end

    def get_session("inactive") do
      send(self(), {:get_session, "inactive"})

      {:ok,
       %{
         ref: "inactive",
         host: "local",
         transport: "local",
         type: "agent",
         state: "active",
         active: false,
         server: "default",
         session: "jx_saysure",
         window: 0,
         pane: 1
       }}
    end

    def get_session("nil-active") do
      send(self(), {:get_session, "nil-active"})

      {:ok,
       %{
         ref: "nil-active",
         host: "local",
         transport: "local",
         type: "agent",
         state: "active",
         active: nil,
         server: "default",
         session: "jx_saysure",
         window: nil,
         pane: nil
       }}
    end

    def get_session(ref) do
      send(self(), {:get_session, ref})

      {:ok,
       %{
         ref: ref,
         host: "local",
         transport: "local",
         type: "agent",
         state: "active",
         active: true,
         server: "default",
         session: "jx_saysure",
         window: 0,
         pane: 1
       }}
    end

    def set_session_profile(ref, attrs) do
      send(self(), {:set_session_profile, ref, attrs})
      {:ok, attrs}
    end

    def session_profiles(opts) do
      send(self(), {:session_profiles, opts})

          case opts[:ref] do
        "empty-profile" ->
          {:ok,
           %{
             generated_at: nil,
             observed: opts[:observe],
             observation_refresh: %{saved: 0},
             operator: %{
               key: "default",
               source: "built-in",
               name: "Op",
               preferences: "pref",
               working_style: "style",
               escalation_policy: "policy",
               notes: "notes",
               updated_at: ""
             },
             total: 0,
             profiles: [],
             errors: []
           }}

        "error-profile" ->
          {:ok,
           %{
             generated_at: DateTime.utc_now(),
             observed: opts[:observe],
             observation_refresh: %{saved: 0},
             operator: %{
               key: "default",
               source: "built-in",
               name: "",
               preferences: "",
               working_style: "",
               escalation_policy: "",
               notes: "",
               updated_at: ""
             },
             total: 0,
             profiles: [],
             errors: [
               %{host: "h1", transport: "t1", subsystem: "s1", error: :atom_error},
               %{host: "h2", transport: "t2", subsystem: "s2", error: "string error"}
             ]
           }}

        "text-profile" ->
          {:ok,
           %{
             generated_at: "2026-05-12T00:00:00Z",
             observed: opts[:observe],
               observation_refresh: %{
                 saved: 5,
                 bool_val: true,
                 text_val: "hello",
                 nested: %{
                   inner_a: 1,
                   inner_b: false,
                   inner_c: "text",
                   inner_d: nil,
                   inner_e: DateTime.utc_now(),
                   inner_f: :atom
                 },
                 struct_val: DateTime.utc_now(),
                 unknown: :atom
               },
              operator: %{
                key: "default",
                source: "built-in",
                name: "Op",
                preferences: "pref",
                working_style: "style",
                escalation_policy: "policy",
                notes: "notes",
                updated_at: "2026-05-12T00:00:00Z"
              },
              total: 1,
              profiles: [
                %{
                  ref: opts[:ref],
                  comparison: %{state: "aligned", actual_summary: String.duplicate("a", 100)},
                  coordination: %{mode: "single", operator_needed: true},
                  planned: %{
                    prompt_status: "ready",
                    expected_completion: String.duplicate("b", 40),
                    objective: String.duplicate("c", 60)
                  },
                  session: %{control_mode: "managed"},
                  actual: %{work_state: "idle"},
                  next_step: String.duplicate("d", 50)
                },
                %{
                  ref: opts[:ref],
                  comparison: %{state: "aligned", actual_summary: "idle"},
                  coordination: %{mode: "single", operator_needed: false},
                  planned: %{
                    prompt_status: "ready",
                    expected_completion: "done",
                    objective: "cover session CLI"
                  },
                  session: %{control_mode: "managed"},
                  actual: %{work_state: "idle"},
                  next_step: "continue"
                },
                %{
                  ref: opts[:ref],
                  comparison: %{state: "aligned", actual_summary: "idle"},
                  coordination: %{mode: "single"},
                  planned: %{
                    prompt_status: "ready",
                    expected_completion: "done",
                    objective: "cover session CLI"
                  },
                  session: %{control_mode: "managed"},
                  actual: %{work_state: "idle"},
                  next_step: "continue"
                }
              ],
              errors: []
            }}

        "mixed-profile" ->
          {:ok,
           %{
             generated_at: "2026-05-12T00:00:00Z",
             observed: opts[:observe],
             observation_refresh: %{saved: 0},
             operator: %{
               key: "default",
               source: "built-in",
               name: "Op",
               preferences: "",
               working_style: "",
               escalation_policy: "",
               notes: "",
               updated_at: ""
             },
             total: 1,
             profiles: [
               %{
                 ref: opts[:ref],
                 comparison: %{state: "aligned", actual_summary: "idle"},
                 coordination: %{mode: "single", operator_needed: false},
                 planned: %{
                   prompt_status: "ready",
                   expected_completion: "done",
                   objective: "cover session CLI"
                 },
                 session: %{control_mode: "managed"},
                 actual: %{work_state: "idle"},
                 next_step: "continue"
               }
             ],
             errors: [
               %{host: "h1", transport: "t1", subsystem: "s1", error: "boom"}
             ]
           }}

        "nil-time-profile" ->
          {:ok,
           %{
             generated_at: nil,
             observed: opts[:observe],
             observation_refresh: %{saved: 0},
             operator: %{
               key: "default",
               source: "built-in",
               name: "",
               preferences: "",
               working_style: "",
               escalation_policy: "",
               notes: "",
               updated_at: ""
             },
             total: 1,
             profiles: [
               %{
                 ref: opts[:ref],
                 comparison: %{state: "aligned", actual_summary: "idle"},
                 coordination: %{mode: "single", operator_needed: false},
                 planned: %{
                   prompt_status: "ready",
                   expected_completion: "done",
                   objective: "cover session CLI"
                 },
                 session: %{control_mode: "managed"},
                 actual: %{work_state: "idle"},
                 next_step: "continue"
               }
             ],
             errors: []
           }}

        _ ->
          {:ok,
           %{
             generated_at: "2026-05-12T00:00:00Z",
             observed: opts[:observe],
             observation_refresh: %{saved: 0},
             operator: %{
               key: "default",
               source: "built-in",
               name: "",
               preferences: "",
               working_style: "",
               escalation_policy: "",
               notes: "",
               updated_at: ""
             },
             total: 1,
             profiles: [
               %{
                 ref: opts[:ref],
                 comparison: %{state: "aligned", actual_summary: "idle"},
                 coordination: %{mode: "single", operator_needed: false},
                 planned: %{
                   prompt_status: "ready",
                   expected_completion: "done",
                   objective: "cover session CLI"
                 },
                 session: %{control_mode: "managed"},
                 actual: %{work_state: "idle"},
                 next_step: "continue"
               }
             ],
             errors: []
           }}
      end
    end

    def set_session_control(ref, mode, opts) do
      send(self(), {:set_session_control, ref, mode, opts})
      {:ok, %{ref: ref, mode: mode}}
    end

    def clear_session_control(ref) do
      send(self(), {:clear_session_control, ref})
      {:ok, %{ref: ref}}
    end

    def send_session_prompt(ref, message, opts) do
      send(self(), {:send_session_prompt, ref, message, opts})
      {:ok, %{directive_id: "dir-1"}}
    end

    def send_session_keys(ref, keys, opts) do
      send(self(), {:send_session_keys, ref, keys, opts})
      {:ok, %{ref: ref, keys: keys, enter: opts[:enter]}}
    end

    def probe_session("probe-remote", opts) do
      send(self(), {:probe_session, "probe-remote", opts})

      {:ok,
       %{
         ref: "probe-remote",
         ssh_target: "build-1",
         target: "default/session:0.1",
         tmux: "ok",
         sessions: 1,
         detail: "shell prompt",
         remote_sessions: [
           %{server: "remote", session: "s1", attached: 1, windows: 2, current_path: "/path"}
         ]
       }}
    end

    def probe_session(ref, opts) do
      send(self(), {:probe_session, ref, opts})

      {:ok,
       %{
         ref: ref,
         ssh_target: "build-1",
         target: "default/session:0.1",
         tmux: "ok",
         sessions: 1,
         detail: "shell prompt",
         remote_sessions: []
       }}
    end

    def stream_adopt_session("resume-available", project, opts) do
      send(self(), {:stream_adopt_session, "resume-available", project, opts})

      {:ok,
       %{
         ref: "resume-available",
         status: "resume-available",
         session: %{kind: "tmux", process_role: "agent", pid: 123},
         next_action: %{command: "jx session resume-adopt resume-available #{project}"},
         reason: "session is available",
         resume_ref: "resume-1",
         zed_workspace: "/workspace"
       }}
    end

    def stream_adopt_session("needs-bridge", project, opts) do
      send(self(), {:stream_adopt_session, "needs-bridge", project, opts})

      {:ok,
       %{
         ref: "needs-bridge",
         status: "needs-bridge",
         session: %{kind: "ssh", pid: nil, tty: "tty1"},
         next_action: %{command: "jx session stream-adopt needs-bridge #{project}"},
         reason: "needs managed stream bridge"
       }}
    end

    def stream_adopt_session(ref, project, opts) do
      send(self(), {:stream_adopt_session, ref, project, opts})
      {:ok, %{ref: ref, status: "adopted", task: task(opts[:agent_name], opts[:agent_transport])}}
    end

    def resume_adopt_session(ref, project, opts) do
      send(self(), {:resume_adopt_session, ref, project, opts})
      {:ok, %{ref: ref, status: "relaunched", task: task(opts[:agent_name], "native")}}
    end

    def adopt_session(ref, project, opts) do
      send(self(), {:adopt_session, ref, project, opts})
      {:ok, task(opts[:agent_name], "native")}
    end

    defp task(agent_name, agent_transport) do
      %{
        task_id: "task-1",
        agent_name: agent_name || "codex",
        agent_transport: agent_transport || "native",
        branch: "jx/task-1",
        worktree_path: "/tmp/worktree",
        tmux_server: "default",
        session_name: "jx_task_1",
        window: 0,
        pane: 1,
        log_path: "/tmp/task.log"
      }
    end
  end

  test "capture owns line parsing and writes raw pane output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["capture", "ref-1", "-n", "12"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:capture_session, "ref-1", [lines: 12]}
    assert output == "recent pane output\n"
  end

  test "capture uses default line count" do
    capture_io(fn ->
      assert :ok =
               Session.run(["capture", "ref-1"],
                 start_app: start_app_callback(),
                 workspace: FakeWorkspace
               )
    end)

    assert_received :started
    assert_received {:capture_session, "ref-1", [lines: 80]}
  end

  test "capture validates line count before starting the app" do
    assert {:error, message} =
             Session.run(["capture", "ref-1", "-n", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "n must be a positive integer"
    refute_received :started
    refute_received :capture_session
  end

  test "capture rejects invalid options and extra args" do
    assert {:error, message} =
             Session.run(["capture", "ref-1", "--bad", "opt"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "invalid options"
    refute_received :started

    assert {:error, message} =
             Session.run(["capture", "ref-1", "extra"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage: jx session capture"
    refute_received :started
  end

  test "attach routes to workspace" do
    assert :ok =
             Session.run(["attach", "ref-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert_received :started
    assert_received {:attach_session, "ref-1"}
  end

  test "attach rejects extra args" do
    assert {:error, message} =
             Session.run(["attach", "ref-1", "extra"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage: jx session attach"
    refute_received :started
  end

  test "inspect renders text table" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["inspect", "ref-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:get_session, "ref-1"}
    assert output =~ "FIELD"
    assert output =~ "ref-1"
    assert output =~ "active"
  end

  test "inspect renders json through the workspace boundary" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["inspect", "ref-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:get_session, "ref-1"}
    assert %{"ref" => "ref-1", "active" => true} = Jason.decode!(output)
  end

  test "inspect handles nil fields in text table" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["inspect", "nil-active"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "FIELD"
    assert output =~ "nil-active"
    assert output =~ "-"
  end

  test "inspect rejects extra args and invalid options" do
    assert {:error, message} =
             Session.run(["inspect", "ref-1", "--bad"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "invalid options"
    refute_received :started

    assert {:error, message} =
             Session.run(["inspect", "ref-1", "extra"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage: jx session inspect"
    refute_received :started
  end

  test "profile updates durable attrs and reads the one-session profile report" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(
                   [
                     "profile",
                     "ref-1",
                     "--summary",
                     "active work",
                     "--objective",
                     "stabilize",
                     "--expect",
                     "done",
                     "--next-prompt",
                     "continue",
                     "--prompt-status",
                     "ready",
                     "--risk",
                     "normal",
                     "--lifecycle",
                     "active",
                     "--stale-after",
                     "60",
                     "--no-observe",
                     "--lines",
                     "15",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:set_session_profile, "ref-1", attrs}
    assert attrs.summary == "active work"
    assert attrs.objective == "stabilize"
    assert attrs.expected_completion == "done"
    assert attrs.next_prompt == "continue"
    assert attrs.prompt_status == "ready"
    assert attrs.risk_level == "normal"
    assert attrs.lifecycle_status == "active"
    assert attrs.stale_after_seconds == 60

    assert_received {:session_profiles, opts}
    assert opts[:ref] == "ref-1"
    assert opts[:observe] == false
    assert opts[:lines] == 15
    assert opts[:limit] == 1

    assert %{"profiles" => [%{"ref" => "ref-1"}], "observed" => false} = Jason.decode!(output)
  end

  test "profile skips set_session_profile when no attrs" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["profile", "ref-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    refute_received {:set_session_profile, _, _}
    assert_received {:session_profiles, opts}
    assert opts[:ref] == "ref-1"
    assert opts[:observe] == true
    assert opts[:lines] == 40
    assert opts[:limit] == 1
    assert output =~ "ref-1"
  end

  test "profile renders text table with profiles" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["profile", "text-profile"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "REF"
    assert output =~ "text-profile"
    assert output =~ "needed"
    assert output =~ "no"
    assert output =~ "OPERATOR"
    assert output =~ "Op"
    assert output =~ "..."
    assert output =~ "bool_val"
    assert output =~ "yes"
    assert output =~ "nested"
    assert output =~ "inner_a"
    assert output =~ "text"
    assert output =~ ":atom"
  end

  test "profile renders empty profiles text" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["profile", "empty-profile"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "no session profiles"
  end

  test "profile renders errors in text table" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["profile", "error-profile", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    decoded = Jason.decode!(output)
    assert decoded["profiles"] == []
    assert length(decoded["errors"]) == 2
    [e1, e2] = decoded["errors"]
    assert e1["error"] == ":atom_error"
    assert e2["error"] == "string error"
  end

  test "profile renders empty profiles json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["profile", "empty-profile", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    decoded = Jason.decode!(output)
    assert decoded["profiles"] == []
    assert decoded["errors"] == []
    assert decoded["generated_at"] == "-"
  end

  test "profile renders text table with profiles and errors" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["profile", "mixed-profile"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "REF"
    assert output =~ "h1"
    assert output =~ "boom"
  end

  test "profile json with nil generated_at formats as dash" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["profile", "nil-time-profile", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    decoded = Jason.decode!(output)
    assert decoded["generated_at"] == "-"
  end

  test "inspect handles inactive field in text table" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["inspect", "inactive"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "FIELD"
    assert output =~ "inactive"
    assert output =~ "no"
  end

  test "profile validates enum options before starting the app" do
    assert {:error, message} =
             Session.run(["profile", "ref-1", "--risk", "urgent"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == ~s(unsupported risk "urgent"; expected one of: low, normal, high, blocked)
    refute_received :started
    refute_received :set_session_profile
  end

  test "profile validates prompt status" do
    assert {:error, message} =
             Session.run(["profile", "ref-1", "--prompt-status", "unknown"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported prompt status"
    refute_received :started
  end

  test "profile validates lifecycle status" do
    assert {:error, message} =
             Session.run(["profile", "ref-1", "--lifecycle", "unknown"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported lifecycle"
    refute_received :started
  end

  test "profile validates stale-after" do
    assert {:error, message} =
             Session.run(["profile", "ref-1", "--stale-after", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "stale-after must be a positive integer"
    refute_received :started
  end

  test "profile validates lines" do
    assert {:error, message} =
             Session.run(["profile", "ref-1", "--lines", "-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "lines must be a positive integer"
    refute_received :started
  end

  test "mark and unmark route session control changes" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(
                   ["mark", "ref-1", "--mode", "managed", "--project", "saysure", "--note", "ok"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )

        assert :ok =
                 Session.run(["unmark", "ref-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:set_session_control, "ref-1", "managed", [project: "saysure", note: "ok"]}

    assert_received {:clear_session_control, "ref-1"}
    assert output =~ "session ref-1 marked managed"
    assert output =~ "session ref-1 unmarked"
  end

  test "mark requires mode" do
    assert {:error, message} =
             Session.run(["mark", "ref-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage: jx session mark"
    refute_received :started
  end

  test "mark validates mode" do
    assert {:error, message} =
             Session.run(["mark", "ref-1", "--mode", "invalid"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported session control mode"
    refute_received :started
  end

  test "send and key preserve no-enter routing" do
    send_output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["send", "ref-1", "continue", "now", "--no-enter"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    key_output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["key", "ref-1", "C-u", "--no-enter", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:send_session_prompt, "ref-1", "continue now", [enter: false]}
    assert_received {:send_session_keys, "ref-1", "C-u", [enter: false]}
    assert send_output =~ "directive dir-1 sent to session ref-1"
    assert %{"keys" => "C-u", "enter" => false} = Jason.decode!(key_output)
  end

  test "send defaults enter true" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["send", "ref-1", "hello"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:send_session_prompt, "ref-1", "hello", [enter: true]}
    assert output =~ "directive dir-1 sent to session ref-1"
  end

  test "send requires message" do
    assert {:error, message} =
             Session.run(["send", "ref-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage: jx session send"
    refute_received :started
  end

  test "key renders text output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["key", "ref-1", "C-c"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:send_session_keys, "ref-1", "C-c", [enter: true]}
    assert output =~ "sent keys to session ref-1"
  end

  test "key requires keys" do
    assert {:error, message} =
             Session.run(["key", "ref-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage: jx session key"
    refute_received :started
  end

  test "probe validates timeout and renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["probe", "ref-1", "--force", "--timeout-ms", "250", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:probe_session, "ref-1", [timeout_ms: 250, force: true]}
    assert %{"ref" => "ref-1", "sessions" => 1} = Jason.decode!(output)
  end

  test "probe defaults timeout" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["probe", "ref-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:probe_session, "ref-1", [timeout_ms: 5000, force: false]}
    assert output =~ "REF"
    assert output =~ "no remote tmux sessions"
  end

  test "probe renders text table with remote sessions" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["probe", "probe-remote"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "REMOTE_SERVER"
    assert output =~ "remote"
    assert output =~ "s1"
  end

  test "probe validates timeout-ms" do
    assert {:error, message} =
             Session.run(["probe", "ref-1", "--timeout-ms", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "timeout-ms must be a positive integer"
    refute_received :started
  end

  test "probe rejects extra args" do
    assert {:error, message} =
             Session.run(["probe", "ref-1", "extra"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage: jx session probe"
    refute_received :started
  end

  test "stream and resume adoption pass agent placement options" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(
                   [
                     "stream-adopt",
                     "ref-1",
                     "saysure",
                     "--agent",
                     "codex",
                     "--transport",
                     "native",
                     "--relaunch",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )

        assert :ok =
                 Session.run(
                   ["resume-adopt", "ref-1", "saysure", "--agent", "codex", "--relaunch"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:stream_adopt_session, "ref-1", "saysure",
                     [agent_name: "codex", agent_transport: "native", relaunch: true]}

    assert_received {:resume_adopt_session, "ref-1", "saysure",
                     [agent_name: "codex", relaunch: true]}

    assert output =~ ~s("status": "adopted")
    assert output =~ "relaunched from session ref-1"
  end

  test "stream-adopt renders text for adopted status" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["stream-adopt", "ref-1", "saysure"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "task task-1 adopted from session ref-1"
    assert output =~ "agent: codex"
  end

  test "stream-adopt renders text for resume-available" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["stream-adopt", "resume-available", "saysure"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "session resume-available can be resume-adopted"
    assert output =~ "reason: session is available"
    assert output =~ "resume: resume-1"
    assert output =~ "workspace: /workspace"
  end

  test "stream-adopt renders text for needs managed stream bridge" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["stream-adopt", "needs-bridge", "saysure"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert output =~ "session needs-bridge needs managed stream bridge"
    assert output =~ "reason: needs managed stream bridge"
    assert output =~ "next: jx session stream-adopt needs-bridge saysure"
  end

  test "stream-adopt validates agent" do
    assert {:error, message} =
             Session.run(
               ["stream-adopt", "ref-1", "saysure", "--agent", "unknown"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported agent"
    refute_received :started
  end

  test "stream-adopt validates transport" do
    assert {:error, message} =
             Session.run(
               ["stream-adopt", "ref-1", "saysure", "--transport", "unknown"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported agent transport"
    refute_received :started
  end

  test "stream-adopt rejects extra args" do
    assert {:error, message} =
             Session.run(
               ["stream-adopt", "ref-1", "saysure", "extra"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage: jx session stream-adopt"
    refute_received :started
  end

  test "stream-adopt defaults transport" do
    capture_io(fn ->
      assert :ok =
               Session.run(["stream-adopt", "ref-1", "saysure"],
                 start_app: start_app_callback(),
                 workspace: FakeWorkspace
               )
    end)

    assert_received {:stream_adopt_session, "ref-1", "saysure",
                     [agent_name: nil, agent_transport: "native", relaunch: false]}
  end

  test "resume-adopt validates agent" do
    assert {:error, message} =
             Session.run(
               ["resume-adopt", "ref-1", "saysure", "--agent", "unknown"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported agent"
    refute_received :started
  end

  test "resume-adopt rejects extra args" do
    assert {:error, message} =
             Session.run(
               ["resume-adopt", "ref-1", "saysure", "extra"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage: jx session resume-adopt"
    refute_received :started
  end

  test "adopt uses claude by default and prints task placement" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["adopt", "ref-1", "saysure"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:adopt_session, "ref-1", "saysure", [agent_name: "claude"]}
    assert output =~ "task task-1 adopted from session ref-1"
    assert output =~ "worktree: /tmp/worktree"
  end

  test "adopt accepts codex agent" do
    output =
      capture_io(fn ->
        assert :ok =
                 Session.run(["adopt", "ref-1", "saysure", "--agent", "codex"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:adopt_session, "ref-1", "saysure", [agent_name: "codex"]}
    assert output =~ "task task-1 adopted from session ref-1"
  end

  test "adopt validates agent name" do
    assert {:error, message} =
             Session.run(
               ["adopt", "ref-1", "saysure", "--agent", "unknown"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported agent"
    refute_received :started
  end

  test "adopt rejects extra args" do
    assert {:error, message} =
             Session.run(
               ["adopt", "ref-1", "saysure", "extra"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage: jx session adopt"
    refute_received :started
  end

  test "run fallback returns usage error" do
    assert {:error, message} = Session.run(["unknown"], start_app: start_app_callback())
    assert message =~ "usage: jx session"
  end

  test "missing start_app callback returns error" do
    assert {:error, :missing_start_app_callback} =
             Session.run(["capture", "ref-1"], workspace: FakeWorkspace)
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
