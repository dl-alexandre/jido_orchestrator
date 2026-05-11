defmodule JX.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI

  test "--help prints top-level usage" do
    output = capture_io(fn -> assert :ok = CLI.run(["--help"]) end)

    assert output =~ "jx orchestrates durable SSH/tmux worktree sessions."
    assert output =~ "jx [--db path] help [group]"
    assert output =~ "Common workflows:"
  end

  test "help group prints focused usage" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "ci"]) end)

    assert output =~ "jx help ci"
    assert output =~ "jx ci digest <pr-number>"
    assert output =~ "jx ci watch <pr-number>"
  end

  test "help orchestrator includes health command" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "orchestrator"]) end)

    assert output =~ "jx help orchestrator"
    assert output =~ "orchestrator start|status|stop|logs|health|heartbeats"
  end

  test "help project includes project brief" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "project"]) end)

    assert output =~ "jx help project"
    assert output =~ "jx project brief <name>"
  end

  test "help fanout includes file-backed assignment commands" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "fanout"]) end)

    assert output =~ "jx help fanout"
    assert output =~ "jx fanout plan <plan-id>"
    assert output =~ "jx fanout preflight <run-id-or-path>"
    assert output =~ "jx fanout launch <run-id-or-path>"
    assert output =~ "jx fanout monitor <run-id-or-path>"
    assert output =~ "jx fanout ownership <run-id-or-path> <assignment-id>"
    assert output =~ "jx fanout pr <run-id-or-path> <assignment-id>"
    assert output =~ "jx fanout status <run-id-or-path>"
  end

  test "help tui includes snapshot, watch, and plan commands" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "tui"]) end)

    assert output =~ "jx help tui"
    assert output =~ "jx tui"
    assert output =~ "jx tui snapshot"
    assert output =~ "jx tui watch"
    assert output =~ "jx tui interactive"
    assert output =~ "jx tui plan"
  end

  test "--help group prints focused usage" do
    output = capture_io(fn -> assert :ok = CLI.run(["--help", "sessions"]) end)

    assert output =~ "jx help sessions"
    assert output =~ "jx sessions queues"
    assert output =~ "jx sessions profiles"
  end

  test "modes prints operator mode catalog" do
    output = capture_io(fn -> assert :ok = CLI.run(["modes"]) end)

    assert output =~ "jx usage modes"
    assert output =~ "tui - Terminal UI"
    assert output =~ "daemon - Detached Daemon"
    assert output =~ "wake - External Wake"
    assert output =~ "jx tui"
  end

  test "modes can print JSON" do
    output = capture_io(fn -> assert :ok = CLI.run(["modes", "--json"]) end)
    decoded = Jason.decode!(output)

    assert %{"modes" => modes} = decoded
    assert Enum.any?(modes, &(&1["id"] == "tui"))
    assert Enum.any?(modes, &(&1["id"] == "wake"))
    assert Enum.any?(modes, &(&1["id"] == "meet"))
  end

  test "modes can print a mode playbook" do
    output = capture_io(fn -> assert :ok = CLI.run(["modes", "wake"]) end)

    assert output =~ "mode wake - External Wake"
    assert output =~ "entrypoint: jx wake --message <text> --project <name>"
    assert output =~ "checks:"
    assert output =~ "switch when:"
  end

  test "modes can print a mode playbook as JSON" do
    output = capture_io(fn -> assert :ok = CLI.run(["modes", "playbook", "wake", "--json"]) end)
    decoded = Jason.decode!(output)

    assert %{"playbook" => playbook} = decoded
    assert playbook["id"] == "wake"
    assert playbook["entrypoint"] == "jx wake --message <text> --project <name>"
    assert "wake" in playbook["available_modes"]
    assert is_list(playbook["checks"])
    assert is_list(playbook["switch_when"])
  end

  test "unknown mode playbook returns available modes" do
    assert {:error, message} = CLI.run(["modes", "unknown"])

    assert message =~ "unknown mode"
    assert message =~ "tui"
    assert message =~ "wake"
  end

  test "help modes prints focused usage" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "modes"]) end)

    assert output =~ "jx help modes"
    assert output =~ "jx modes [<mode>|playbook <mode>] [--json]"
  end

  test "fanout plan creates a run from the CLI" do
    root =
      Path.join(
        System.tmp_dir!(),
        "jx-fanout-cli-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "fanout",
                   "plan",
                   "test-coverage",
                   "--baseline",
                   "53907e03",
                   "--root",
                   root,
                   "--run-id",
                   "test-coverage-cli"
                 ])
      end)

    assert output =~ "fanout run planned"
    assert output =~ "auth-api-security"
    assert File.exists?(Path.join([root, "test-coverage-cli", "run_manifest.json"]))
  end

  test "help next prints focused usage" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "next"]) end)

    assert output =~ "jx help next"
    assert output =~ "jx next"
    assert output =~ "--no-observe"
  end

  test "tui plan prints the monitor loop" do
    output = capture_io(fn -> assert :ok = CLI.run(["tui", "plan"]) end)

    assert output =~ "jx TUI runbook"
    assert output =~ "monitor loop"
    assert output =~ "jx tui --no-observe"
  end

  test "tui snapshot prints a monitorable snapshot" do
    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "tui",
                   "snapshot",
                   "--no-observe",
                   "--consumer",
                   "cli-tui-test"
                 ])
      end)

    assert output =~ "jx TUI"
    assert output =~ "NEXT"
    assert output =~ "QUEUE"
    assert output =~ "DAEMON"
    assert output =~ "INBOX"
    assert output =~ "ACTIONS"
    refute output =~ "FIELD    VALUE"
  end

  test "tui opens the steering loop by default" do
    output =
      capture_io("q\n", fn ->
        assert :ok =
                 CLI.run([
                   "tui",
                   "--no-observe",
                   "--no-clear",
                   "--consumer",
                   "cli-tui-default-interactive-test"
                 ])
      end)

    assert output =~ "jx TUI"
    assert output =~ "STEER"
    assert output =~ "j/k move"
  end

  test "tui interactive remains an explicit steering alias" do
    output =
      capture_io("q\n", fn ->
        assert :ok =
                 CLI.run([
                   "tui",
                   "interactive",
                   "--no-observe",
                   "--no-clear",
                   "--consumer",
                   "cli-tui-interactive-test"
                 ])
      end)

    assert output =~ "jx TUI"
    assert output =~ "STEER"
    assert output =~ "j/k move"
    assert output =~ "d draft prompt"
    assert output =~ "s send confirmed prompt"
  end

  test "tui interactive rejects json mode" do
    assert {:error, message} = CLI.run(["tui", "interactive", "--json"])

    assert message =~ "cannot be combined with --json"
  end

  test "tui can print JSON" do
    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "tui",
                   "--no-observe",
                   "--consumer",
                   "cli-tui-json-test",
                   "--json"
                 ])
      end)

    decoded = Jason.decode!(output)

    assert decoded["monitor"]["consumer"] == "cli-tui-json-test"
    assert decoded["next"]["command"]
    assert Enum.any?(decoded["commands"], &(&1["label"] == "watch"))
  end

  test "help wake prints focused usage" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "wake"]) end)

    assert output =~ "jx help wake"
    assert output =~ "jx wake --message <text>"
    assert output =~ "jx wake add --message <text>"
    assert output =~ "jx wake run-due"
  end

  test "help policy includes safety tiers" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "policy"]) end)

    assert output =~ "jx policy tiers [--json]"
  end

  test "policy tiers prints safety ladder" do
    output = capture_io(fn -> assert :ok = CLI.run(["policy", "tiers"]) end)

    assert output =~ "policy safety tiers"
    assert output =~ "inspect: Inspect Only"
    assert output =~ "held-release: Held Release Or Destructive Action"
  end

  test "policy tiers can print JSON" do
    output = capture_io(fn -> assert :ok = CLI.run(["policy", "tiers", "--json"]) end)
    decoded = Jason.decode!(output)

    assert %{"tiers" => tiers} = decoded
    assert Enum.any?(tiers, &(&1["id"] == "gated"))
    assert Enum.any?(tiers, &(&1["id"] == "held-release"))
  end

  test "unknown help group returns available groups" do
    assert {:error, message} = CLI.run(["help", "unknown"])

    assert message =~ "unknown help group"
    assert message =~ "available groups:"
    assert message =~ "ci"
    assert message =~ "sessions"
  end
end
