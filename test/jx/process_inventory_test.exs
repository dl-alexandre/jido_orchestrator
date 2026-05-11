defmodule JX.ProcessInventoryTest do
  use ExUnit.Case, async: true

  alias JX.ProcessInventory

  test "parse_ps_output classifies agent and ssh processes" do
    output = """
      PID  PPID STAT TTY      COMMAND
      101     1 S    ttys001  node /Users/developer/.nvm/bin/codex
      102     1 S+   ttys002  claude --dangerously-skip-permissions
      103     1 S+   ttys003  opencode
      104     1 S+   ttys004  ssh build-1-remote
      105     1 S    ??       sshd-session: developer [priv]
      106     1 S+   ttys005  tmux attach -t mm
      107     1 S+   ttys006  zsh
      108     1 Ss   ??       beam.smp -- process ls --kind codex
      109     1 S+   ttys007  ssh remote OPENAI_API_KEY=sk-test --password sword
      110     1 S    ??       /Applications/Codex.app/Contents/MacOS/Codex
      111     1 S    ??       /Applications/Codex.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient mcp
      112     1 S    ??       /Users/user-a/.local/share/zed/external_agents/registry/codex-acp/v_0.12.0/codex-acp
      113     1 S    ??       /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=gpu-process
      200     1 S    ??       /home/user-a/.zed_server/zed run --pid-file /home/user-a/.local/share/zed/server_state/workspace-10/server.pid
      201   200 S    ??       /home/user-a/.local/share/zed/node/cache/_npx/pkg/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64/claude --output-format stream-json --input-format stream-json --resume 00000000-0000-0000-0000-000000000000
    """

    processes = ProcessInventory.parse_ps_output(output)

    assert Enum.map(processes, &{&1.kind, &1.role, &1.pid, &1.tty}) == [
             {"codex", "cli", 101, "ttys001"},
             {"claude", "cli", 102, "ttys002"},
             {"opencode", "cli", 103, "ttys003"},
             {"ssh", "process", 104, "ttys004"},
             {"sshd", "process", 105, "??"},
             {"tmux", "process", 106, "ttys005"},
             {"ssh", "process", 109, "ttys007"},
             {"codex", "desktop", 110, "??"},
             {"codex", "mcp", 111, "??"},
             {"codex", "acp", 112, "??"},
             {"claude", "helper", 113, "??"},
             {"claude", "acp", 201, "??"}
           ]

    secret_process = Enum.find(processes, &(&1.pid == 109))
    assert secret_process.command == "ssh remote OPENAI_API_KEY=<redacted> --password <redacted>"

    zed_process = Enum.find(processes, &(&1.pid == 201))
    assert zed_process.resume_available
    assert zed_process.resume_ref =~ "resume-"
    assert zed_process.zed_workspace == "workspace-10"
    refute zed_process.command =~ "00000000"
  end
end
