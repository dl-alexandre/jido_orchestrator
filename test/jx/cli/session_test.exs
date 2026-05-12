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

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
