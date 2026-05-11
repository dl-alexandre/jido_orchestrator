defmodule JX.SSHSessionsTest do
  use ExUnit.Case, async: true

  alias JX.SSHSessions

  test "parse_target extracts outbound ssh targets" do
    assert SSHSessions.parse_target("ssh build-1-remote") == "build-1-remote"

    assert SSHSessions.parse_target("ssh -o BatchMode=yes -p 2223 milc@example.test") ==
             "milc@example.test"

    assert SSHSessions.parse_target("/usr/bin/ssh -tt laptop-1") == "laptop-1"
  end

  test "parse_target handles helpers and inbound sshd sessions" do
    assert SSHSessions.parse_target("sshs") == ""
    assert SSHSessions.parse_target("sshd-session: developer [priv]") == "developer"
    assert SSHSessions.parse_target("sshd-session: developer@ttys018") == "developer@ttys018"
  end

  test "parse_probe_output parses structured remote tmux sessions" do
    output = """
    can_execute\tok
    tmux\tok
    session|default|one|1700000000|1|2|/srv/one
    session|socket:agent|two|1700000001|0|1|/srv/two
    """

    assert SSHSessions.parse_probe_output(output) == %{
             tmux: "ok",
             sessions: 2,
             remote_sessions: [
               %{
                 server: "default",
                 session: "one",
                 created: 1_700_000_000,
                 attached: 1,
                 windows: 2,
                 current_path: "/srv/one"
               },
               %{
                 server: "socket:agent",
                 session: "two",
                 created: 1_700_000_001,
                 attached: 0,
                 windows: 1,
                 current_path: "/srv/two"
               }
             ],
             detail: ""
           }
  end

  test "parse_probe_output accepts whitespace-delimited captured pane output" do
    output = """
    can_execute     ok
    tmux    ok
    session defaultagent-pane-probe-smoke177710023101
    session socket:agent-pane-probe-smokeagent-pane-probe-smoke177710023101
    """

    assert SSHSessions.parse_probe_output(output) == %{
             tmux: "ok",
             sessions: 2,
             remote_sessions: [],
             detail: ""
           }
  end

  test "parse_probe_output keeps tmux errors actionable" do
    output = """
    can_execute\tok
    tmux\tok
    tmux_sessions_error\tno server running on /tmp/tmux-501/default
    """

    assert SSHSessions.parse_probe_output(output) == %{
             tmux: "ok",
             sessions: 0,
             remote_sessions: [],
             detail: "no server running on /tmp/tmux-501/default"
           }
  end

  test "remote tmux probe scripts use an explicit default tmux socket" do
    assert SSHSessions.remote_tmux_all_script() =~ "emit_sessions default tmux -L default"
    assert SSHSessions.remote_tmux_probe_script() =~ "emit_sessions default tmux -L default"
  end
end
