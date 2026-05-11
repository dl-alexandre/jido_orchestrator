defmodule JX.PaneTransportTest do
  use ExUnit.Case, async: false

  alias JX.PaneTransport

  test "parse_marked_output extracts output between exact marker lines" do
    output = """
    sh -lc 'printf "__JX_START_probe__\\n"'
    __JX_START_probe__
    can_execute\tok
    tmux\tok
    session\tdefault\tone\t1\t0\t1\t/tmp/repo
    __JX_END_probe__:0
    prompt %
    """

    assert PaneTransport.parse_marked_output(output, "probe") ==
             {:ok, "can_execute\tok\ntmux\tok\nsession\tdefault\tone\t1\t0\t1\t/tmp/repo"}
  end

  test "parse_marked_output ignores partial marker references in echoed commands" do
    output = """
    sh -lc 'printf "__JX_START_probe__\\n"; printf "__JX_END_probe__:0\\n"'
    still running
    """

    assert PaneTransport.parse_marked_output(output, "probe") == :not_found
  end

  test "parse_marked_output waits until end marker is present" do
    output = """
    __JX_START_probe__
    can_execute\tok
    tmux\tok
    """

    assert PaneTransport.parse_marked_output(output, "probe") == :not_found
  end

  test "ssh_pane_candidates keeps outbound ssh panes with tmux coordinates" do
    sessions = [
      ssh_session(target: "one", server: "default", session: "mm", window: 0, pane: 0),
      ssh_session(target: "one", server: "default", session: "mm", window: 0, pane: 0, pid: 200),
      ssh_session(target: "two", server: "default", session: "mm", window: 0, pane: 1),
      ssh_session(target: "three", server: "", session: "", window: nil, pane: nil),
      %{
        ssh_session(target: "four", server: "default", session: "ox", window: 0, pane: 0)
        | role: "helper"
      }
    ]

    candidates = PaneTransport.ssh_pane_candidates(sessions)

    assert Enum.map(candidates, &{&1.target, &1.session, &1.pane, &1.pid}) == [
             {"one", "mm", 0, 100},
             {"two", "mm", 1, 100}
           ]
  end

  test "ssh_pane_candidates filters by ssh target" do
    sessions = [
      ssh_session(target: "one", server: "default", session: "mm", window: 0, pane: 0),
      ssh_session(target: "two", server: "default", session: "mm", window: 0, pane: 1)
    ]

    assert [%{target: "two", pane: 1}] =
             PaneTransport.ssh_pane_candidates(sessions, target: "two")
  end

  test "probe executes through tmux and parses marked SSH session output" do
    install_fake_tmux!()

    assert {:ok, probe} =
             PaneTransport.probe(
               tmux_server: "jx",
               session_name: "remote",
               window: 1,
               pane: 2,
               timeout_ms: 100,
               capture_lines: 50
             )

    assert probe.tmux == "ok"
    assert probe.sessions == 1
    assert probe.server == "jx"
    assert probe.session == "remote"
    assert probe.window == 1
    assert probe.pane == 2
    assert probe.target == "jx/remote:1.2"
  end

  test "probe_ssh_candidates returns ok and error summaries" do
    install_fake_tmux!()

    [ok_probe] =
      PaneTransport.probe_ssh_candidates([
        ssh_session(target: "one", server: "jx", session: "remote", window: 0, pane: 0)
      ])

    assert ok_probe.status == "ok"
    assert ok_probe.ssh_target == "one"

    System.put_env("TMUX_FAIL", "pane")

    [error_probe] =
      PaneTransport.probe_ssh_candidates([
        ssh_session(target: "two", server: "jx", session: "missing", window: 0, pane: 0)
      ])

    assert error_probe.status == "error"
    assert error_probe.error == {:pane_transport_failed, "pane", 2, "missing pane\n"}
  end

  defp ssh_session(attrs) do
    %{
      role: Keyword.get(attrs, :role, "outbound"),
      target: Keyword.fetch!(attrs, :target),
      registered_host: Keyword.get(attrs, :registered_host, ""),
      pid: Keyword.get(attrs, :pid, 100),
      server: Keyword.fetch!(attrs, :server),
      session: Keyword.fetch!(attrs, :session),
      window: Keyword.fetch!(attrs, :window),
      pane: Keyword.fetch!(attrs, :pane)
    }
  end

  defp install_fake_tmux! do
    tmp = Path.join(System.tmp_dir!(), "jx-pane-tmux-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    tmux_path = Path.join(tmp, "tmux")
    log_path = Path.join(tmp, "tmux.log")

    File.write!(tmux_path, """
    #!/bin/sh
    args="$*"
    printf '%s\n' "$args" >> "$TMUX_LOG"

    case "$args" in
      *display-message*)
        if [ "$TMUX_FAIL" = "pane" ]; then
          printf 'missing pane\n'
          exit 2
        fi
        printf '%%1\n'
        exit 0
        ;;
      *send-keys*)
        exit 0
        ;;
      *capture-pane*)
        marker=$(grep -o '__JX_START_[0-9a-f]*__' "$TMUX_LOG" | tail -1 | sed 's/__JX_START_//;s/__//')
        if [ -z "$marker" ]; then
          exit 0
        fi
        printf '__JX_START_%s__\n' "$marker"
        printf 'can_execute\tok\n'
        printf 'tmux\tok\n'
        printf 'session|default\tone\t1\t0\t1\t/tmp/repo\n'
        printf '__JX_END_%s__:0\n' "$marker"
        exit 0
        ;;
      *)
        printf 'unexpected tmux args: %s\n' "$args"
        exit 2
        ;;
    esac
    """)

    File.chmod!(tmux_path, 0o755)

    old_path = System.get_env("PATH")
    System.put_env("PATH", tmp <> ":" <> (old_path || ""))
    System.put_env("TMUX_LOG", log_path)
    System.delete_env("TMUX_FAIL")

    on_exit(fn ->
      if old_path, do: System.put_env("PATH", old_path), else: System.delete_env("PATH")
      System.delete_env("TMUX_LOG")
      System.delete_env("TMUX_FAIL")
      File.rm_rf(tmp)
    end)
  end
end
