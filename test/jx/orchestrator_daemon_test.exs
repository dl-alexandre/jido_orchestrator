defmodule JX.OrchestratorDaemonTest do
  use ExUnit.Case, async: false

  alias JX.OrchestratorDaemon
  alias JX.Repo
  alias JX.ResourceOwnerships.Resource

  defmodule FailingResourceOwnerships do
    def register_tmux_session(_attrs), do: {:error, :forced_registry_failure}
  end

  setup do
    original_resource_ownerships = Application.get_env(:jx, :resource_ownerships)
    Application.delete_env(:jx, :resource_ownerships)
    Repo.delete_all(Resource)

    on_exit(fn ->
      if original_resource_ownerships do
        Application.put_env(:jx, :resource_ownerships, original_resource_ownerships)
      else
        Application.delete_env(:jx, :resource_ownerships)
      end
    end)

    :ok
  end

  test "orchestrate_args defaults to an executing acknowledged infinite loop" do
    assert OrchestratorDaemon.orchestrate_args(
             lines: 200,
             interval_ms: 12_000,
             queue_limit: 8,
             min_observe_age_seconds: 10
           ) == [
             "orchestrate",
             "run",
             "--lines",
             "200",
             "--scan-limit",
             "100",
             "--queue-limit",
             "8",
             "--event-limit",
             "50",
             "--decision-limit",
             "20",
             "--min-observe-age-seconds",
             "10",
             "--interval-ms",
             "12000",
             "--iterations",
             "0",
             "--execute",
             "--yes",
             "--ack",
             "--auto-plan"
           ]
  end

  test "orchestrate_args preserves filters and conservative switches" do
    args =
      OrchestratorDaemon.orchestrate_args(
        consumer: "night-watch",
        host_name: "local",
        all_tmux: false,
        all_processes: true,
        type: "agent",
        ssh_target: "box",
        work_state: "waiting",
        control_mode: "managed",
        prompt_status: "ready",
        observe: false,
        execute: false,
        yes: false,
        ack: false,
        auto_plan: false,
        enter: false
      )

    assert "--consumer" in args
    assert "night-watch" in args
    assert "--host" in args
    assert "local" in args
    assert "--managed" in args
    assert "--all-processes" in args
    assert "--type" in args
    assert "agent" in args
    assert "--ssh-target" in args
    assert "box" in args
    assert "--work-state" in args
    assert "waiting" in args
    assert "--control" in args
    assert "managed" in args
    assert "--prompt-status" in args
    assert "ready" in args
    assert "--no-observe" in args
    refute "--execute" in args
    refute "--yes" in args
    assert "--no-ack" in args
    refute "--auto-plan" in args
    assert "--no-enter" in args
  end

  test "orchestrate_args supports dry-run daemon mode" do
    args = OrchestratorDaemon.orchestrate_args(dry_run: true)

    refute "--execute" in args
    refute "--yes" in args
    assert "--no-ack" in args
    assert "--auto-plan" in args
  end

  test "loop_command carries db path through environment and appends to log" do
    command =
      OrchestratorDaemon.loop_command(
        cli_path: "/tmp/bin jx",
        db_path: "/tmp/jx.sqlite3",
        log_path: "/tmp/orchestrator log.txt",
        cwd: "/tmp/work",
        session_name: "jx-orchestrator-test",
        interval_ms: 5_000
      )

    assert command =~ "'exec' 'env'"
    assert command =~ "'JX_DB=/tmp/jx.sqlite3'"
    assert command =~ "'/tmp/bin jx'"
    assert command =~ "'orchestrate' 'run'"
    assert command =~ "'--interval-ms' '5000'"
    assert command =~ ">> '/tmp/orchestrator log.txt' 2>&1"
  end

  test "start status logs and stop use tmux command results" do
    {tmp, log_path} = install_fake_tmux!()

    opts = [
      session_name: "jx-orchestrator-test",
      tmux_server: "jx",
      log_path: log_path,
      cwd: tmp,
      cli_path: "/tmp/jx",
      dry_run: true,
      replace: true
    ]

    assert {:ok, stopped} = OrchestratorDaemon.status(opts)
    assert stopped.running == false

    assert {:ok, started} = OrchestratorDaemon.start(opts)
    assert started.running == true
    assert started.started == true
    assert started.command =~ "orchestrate"

    assert %Resource{
             owner_type: "orchestrator_daemon",
             owner_project: "orchestrator",
             resource_type: "tmux_session",
             resource_name: "jx-orchestrator-test",
             tmux_server: "jx",
             cleanup_policy: "kill_tmux_session"
           } = Repo.get_by!(Resource, resource_name: "jx-orchestrator-test")

    File.write!(log_path, "one\ntwo\nthree")
    assert {:ok, logs} = OrchestratorDaemon.logs(Keyword.put(opts, :lines, 2))
    assert logs.output == "two\nthree"

    assert {:ok, stopped_again} = OrchestratorDaemon.stop(opts)
    assert stopped_again.running == false
    assert stopped_again.stopped == true

    assert {:ok, already_stopped} = OrchestratorDaemon.stop(opts)
    assert already_stopped.stopped == false
  end

  test "start tears down daemon tmux session when ownership registration fails" do
    {tmp, log_path} = install_fake_tmux!()
    Application.put_env(:jx, :resource_ownerships, FailingResourceOwnerships)

    opts = [
      session_name: "jx-orchestrator-fail",
      tmux_server: "jx",
      log_path: log_path,
      cwd: tmp,
      cli_path: "/tmp/jx",
      dry_run: true,
      replace: true
    ]

    assert {:error, {:orchestrator_resource_registration_failed, :forced_registry_failure}} =
             OrchestratorDaemon.start(opts)

    assert {:ok, status} = OrchestratorDaemon.status(opts)
    assert status.running == false
  end

  test "daemon validation rejects unsafe session and tmux server names" do
    assert {:error, {:invalid_orchestrator_session, "bad session"}} =
             OrchestratorDaemon.status(session_name: "bad session")

    assert {:error, {:invalid_tmux_server, "bad server"}} =
             OrchestratorDaemon.status(tmux_server: "bad server")
  end

  defp install_fake_tmux! do
    tmp = Path.join(System.tmp_dir!(), "jx-fake-tmux-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    state_path = Path.join(tmp, "tmux-state")
    log_path = Path.join(tmp, "daemon.log")
    tmux_path = Path.join(tmp, "tmux")

    File.write!(tmux_path, """
    #!/bin/sh
    args="$*"
    case "$args" in
      *has-session*)
        test -f "$TMUX_STATE"
        exit $?
        ;;
      *new-session*)
        printf running > "$TMUX_STATE"
        exit 0
        ;;
      *list-panes*)
        printf '1710000000\t0\t12345\tjx\t/tmp/work\n'
        exit 0
        ;;
      *kill-session*)
        rm -f "$TMUX_STATE"
        exit 0
        ;;
      *)
        printf 'unexpected tmux args: %s\n' "$args" >&2
        exit 2
        ;;
    esac
    """)

    File.chmod!(tmux_path, 0o755)

    old_path = System.get_env("PATH")
    System.put_env("PATH", tmp <> ":" <> (old_path || ""))
    System.put_env("TMUX_STATE", state_path)

    on_exit(fn ->
      if old_path, do: System.put_env("PATH", old_path), else: System.delete_env("PATH")
      System.delete_env("TMUX_STATE")
      File.rm_rf(tmp)
    end)

    {tmp, log_path}
  end
end
