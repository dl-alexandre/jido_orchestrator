defmodule JX.CLI.SSHTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.SSH

  defmodule FakeWorkspace do
    def list_hosts do
      send(self(), :list_hosts)
      [%{name: "build-1", transport: "ssh"}]
    end
  end

  defmodule FakeSSHSessions do
    def list(hosts) do
      send(self(), {:ssh_list, hosts})

      {:ok,
       [
         %{
           role: "client",
           pid: 123,
           stat: "S+",
           tty: "ttys001",
           target: "build-1",
           registered_host: "build-1",
           server: "default",
           session: "jx_saysure",
           window: 0,
           pane: 1,
           current_path: "/repo",
           title: "agent",
           command: "ssh build-1"
         }
       ]}
    end

    def active_targets do
      send(self(), :active_targets)
      {:ok, ["build-1", "build-2"]}
    end

    def probe(targets) do
      send(self(), {:probe_targets, targets})

      {:ok,
       Enum.map(targets, fn target ->
         %{target: target, ssh: "ok", tmux: "ok", sessions: 1, detail: "ready"}
       end)}
    end
  end

  defmodule FakePaneTransport do
    def ssh_pane_candidates(sessions, opts) do
      send(self(), {:ssh_pane_candidates, sessions, opts})

      [
        %{
          target: opts[:target] || "build-1",
          registered_host: "build-1",
          pid: 123,
          server: "default",
          session: "jx_saysure",
          window: 0,
          pane: 1,
          current_path: "/repo",
          title: "agent"
        }
      ]
    end

    def probe_ssh_sessions(sessions, opts) do
      send(self(), {:probe_ssh_sessions, sessions, opts})

      [
        %{
          ssh_target: opts[:target] || "build-1",
          registered_host: "build-1",
          pid: 123,
          target: "default/jx_saysure:0.1",
          status: "ok",
          tmux: "ok",
          sessions: 1,
          detail: "ready"
        }
      ]
    end

    def probe(opts) do
      send(self(), {:pane_probe, opts})

      {:ok,
       %{
         target: "#{opts[:tmux_server]}/#{opts[:session_name]}:#{opts[:window]}.#{opts[:pane]}",
         tmux: "ok",
         sessions: 1,
         detail: "ready"
       }}
    end
  end

  test "ls starts the app and renders ssh sessions" do
    output =
      capture_io(fn ->
        assert :ok =
                 SSH.run(["ls"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace,
                   ssh_sessions: FakeSSHSessions
                 )
      end)

    assert_received :started
    assert_received :list_hosts
    assert_received {:ssh_list, [%{name: "build-1", transport: "ssh"}]}
    assert output =~ "ROLE"
    assert output =~ "build-1"
  end

  test "probe with target avoids app startup and probes that target" do
    output =
      capture_io(fn ->
        assert :ok =
                 SSH.run(["probe", "--target", "build-1"],
                   start_app: start_app_callback(),
                   ssh_sessions: FakeSSHSessions
                 )
      end)

    refute_received :started
    refute_received :active_targets
    assert_received {:probe_targets, ["build-1"]}
    assert output =~ "TARGET"
    assert output =~ "build-1"
  end

  test "probe without target uses active ssh targets" do
    output =
      capture_io(fn ->
        assert :ok =
                 SSH.run(["probe"],
                   start_app: start_app_callback(),
                   ssh_sessions: FakeSSHSessions
                 )
      end)

    refute_received :started
    assert_received :active_targets
    assert_received {:probe_targets, ["build-1", "build-2"]}
    assert output =~ "build-2"
  end

  test "pane-probe all dry-run inventories candidates through ssh sessions" do
    output =
      capture_io(fn ->
        assert :ok =
                 SSH.run(["pane-probe", "--all", "--target", "build-1", "--dry-run"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace,
                   ssh_sessions: FakeSSHSessions,
                   pane_transport: FakePaneTransport
                 )
      end)

    assert_received :started
    assert_received :list_hosts
    assert_received {:ssh_list, [_host]}
    assert_received {:ssh_pane_candidates, [_session], [target: "build-1"]}
    assert output =~ "SSH_TARGET"
    assert output =~ "default/jx_saysure:0.1"
  end

  test "pane-probe all can run remote probes" do
    output =
      capture_io(fn ->
        assert :ok =
                 SSH.run(["pane-probe", "--all", "--timeout-ms", "250"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace,
                   ssh_sessions: FakeSSHSessions,
                   pane_transport: FakePaneTransport
                 )
      end)

    assert_received :started
    assert_received {:probe_ssh_sessions, [_session], [target: nil, timeout_ms: 250]}
    assert output =~ "STATUS"
    assert output =~ "ready"
  end

  test "pane-probe one validates and routes pane coordinates" do
    output =
      capture_io(fn ->
        assert :ok =
                 SSH.run(
                   [
                     "pane-probe",
                     "--session",
                     "jx_saysure",
                     "--server",
                     "default",
                     "--window",
                     "2",
                     "--pane",
                     "3",
                     "--timeout-ms",
                     "400"
                   ],
                   start_app: start_app_callback(),
                   pane_transport: FakePaneTransport
                 )
      end)

    refute_received :started

    assert_received {:pane_probe,
                     [
                       session_name: "jx_saysure",
                       tmux_server: "default",
                       window: 2,
                       pane: 3,
                       timeout_ms: 400
                     ]}

    assert output =~ "PANE"
    assert output =~ "default/jx_saysure:2.3"
  end

  test "pane-probe validates timeout before side effects" do
    assert {:error, message} =
             SSH.run(["pane-probe", "--all", "--timeout-ms", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace,
               ssh_sessions: FakeSSHSessions,
               pane_transport: FakePaneTransport
             )

    assert message == "timeout-ms must be a positive integer"
    refute_received :started
    refute_received :list_hosts
    refute_received :ssh_list
    refute_received :probe_ssh_sessions
  end

  test "unknown ssh command returns focused usage" do
    assert {:error, message} = SSH.run(["unknown"], start_app: start_app_callback())

    assert message =~ "usage: jx ssh ls"
    assert message =~ "jx ssh pane-probe"
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
