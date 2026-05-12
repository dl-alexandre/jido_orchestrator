defmodule JX.CLI.TmuxTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Tmux

  defmodule FakeWorkspace do
    def list_tmux_sessions(host, opts) do
      send(self(), {:list_tmux_sessions, host, opts})

      {:ok,
       [
         %{
           server: opts[:tmux_server],
           name: "jx_saysure",
           created_at: "2026-05-12T00:00:00Z",
           attached: 1,
           windows: 2,
           current_path: "/repo"
         }
       ]}
    end

    def list_tmux_panes(host, opts) do
      send(self(), {:list_tmux_panes, host, opts})

      {:ok,
       [
         %{
           server: opts[:tmux_server],
           session: "jx_saysure",
           window: 0,
           pane: 1,
           tty: "ttys001",
           active: true,
           kind: "codex",
           command: "codex",
           current_path: "/repo",
           title: "agent"
         }
       ]}
    end

    def capture_tmux_pane(host, session, opts) do
      send(self(), {:capture_tmux_pane, host, session, opts})
      {:ok, "pane output\n"}
    end

    def send_tmux(host, session, message, opts) do
      send(self(), {:send_tmux, host, session, message, opts})
      {:ok, %{directive_id: "dir-1"}}
    end

    def attach_tmux(host, session, opts) do
      send(self(), {:attach_tmux, host, session, opts})
      :ok
    end

    def stop_tmux(host, session, opts) do
      send(self(), {:stop_tmux, host, session, opts})
      :ok
    end
  end

  test "ls owns tmux session parsing and output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Tmux.run(["ls", "build-1", "--server", "default"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:list_tmux_sessions, "build-1", [all_tmux: nil, tmux_server: "default"]}
    assert output =~ "SERVER"
    assert output =~ "jx_saysure"
  end

  test "ls rejects mutually exclusive server selectors before starting the app" do
    assert {:error, message} =
             Tmux.run(["ls", "build-1", "--all", "--server", "default"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "use either --all or --server, not both"
    refute_received :started
    refute_received :list_tmux_sessions
  end

  test "panes renders pane inventory" do
    output =
      capture_io(fn ->
        assert :ok =
                 Tmux.run(["panes", "build-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:list_tmux_panes, "build-1", [all_tmux: nil, tmux_server: "jx"]}
    assert output =~ "PANE"
    assert output =~ "codex"
  end

  test "capture validates pane coordinates and writes raw output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Tmux.run(
                   [
                     "capture",
                     "build-1",
                     "jx_saysure",
                     "--window",
                     "2",
                     "--pane",
                     "3",
                     "-n",
                     "12"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started

    assert_received {:capture_tmux_pane, "build-1", "jx_saysure",
                     [tmux_server: "jx", window: 2, pane: 3, lines: 12]}

    assert output == "pane output\n"
  end

  test "capture rejects invalid line count before starting the app" do
    assert {:error, message} =
             Tmux.run(["capture", "build-1", "jx_saysure", "-n", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "n must be a positive integer"
    refute_received :started
    refute_received :capture_tmux_pane
  end

  test "send joins message parts and preserves no-enter routing" do
    output =
      capture_io(fn ->
        assert :ok =
                 Tmux.run(["send", "build-1", "jx_saysure", "continue", "now", "--no-enter"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started

    assert_received {:send_tmux, "build-1", "jx_saysure", "continue now",
                     [tmux_server: "jx", window: 0, pane: 0, enter: false]}

    assert output =~ "directive dir-1 sent to build-1/jx/jx_saysure:0.0"
  end

  test "attach and stop route to workspace boundary" do
    output =
      capture_io(fn ->
        assert :ok =
                 Tmux.run(["attach", "build-1", "jx_saysure", "--server", "default"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )

        assert :ok =
                 Tmux.run(["stop", "build-1", "jx_saysure", "--server", "default"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received {:attach_tmux, "build-1", "jx_saysure", [tmux_server: "default"]}
    assert_received {:stop_tmux, "build-1", "jx_saysure", [tmux_server: "default"]}
    assert output =~ "tmux session jx_saysure stopped on build-1/default"
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
