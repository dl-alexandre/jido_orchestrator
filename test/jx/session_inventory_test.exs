defmodule JX.SessionInventoryTest do
  use ExUnit.Case, async: true

  alias JX.SessionInventory

  test "build classifies managed tasks, ssh panes, agents, and standalone ssh" do
    activity_report = %{
      activity: [
        activity(
          host: "local",
          server: "jx",
          session: "managed",
          window: 0,
          pane: 0,
          kind: "codex",
          process_pid: 10,
          current_path: "/tmp/worktree"
        ),
        activity(
          host: "local",
          server: "default",
          session: "mm",
          window: 0,
          pane: 1,
          kind: "ssh",
          process_pid: 20,
          current_path: "/Users/developer"
        ),
        activity(
          host: "local",
          server: "default",
          session: "manual",
          window: 1,
          pane: 0,
          kind: "opencode",
          process_pid: 30,
          current_path: "/repo"
        ),
        activity(
          host: "local",
          server: "",
          session: "",
          window: nil,
          pane: nil,
          kind: "ssh",
          process_pid: 50,
          current_path: ""
        )
      ],
      errors: []
    }

    ssh_sessions = [
      ssh_session(
        target: "build-1-remote",
        server: "default",
        session: "mm",
        window: 0,
        pane: 1
      ),
      ssh_session(target: "laptop-1", server: "", session: "", window: nil, pane: nil, pid: 40),
      ssh_session(target: "uitest", server: "", session: "", window: nil, pane: nil, pid: 50)
    ]

    tasks = [
      %{
        task_id: "task-123",
        status: "running",
        agent_name: "codex",
        tmux_server: "jx",
        session_name: "managed",
        window: 0,
        pane: 0,
        host: %{name: "local"},
        project: %{name: "saysure"}
      }
    ]

    report = SessionInventory.build(activity_report, ssh_sessions, tasks)
    refs = Enum.map(report.sessions, & &1.ref)

    assert Enum.all?(refs, &String.starts_with?(&1, "s-"))
    assert Enum.uniq(refs) == refs
    assert SessionInventory.find(report.sessions, List.first(refs)).ref == List.first(refs)

    assert Enum.map(report.sessions, &{&1.type, &1.state, &1.session, &1.ssh_target}) == [
             {"ssh", "unmanaged", "", "laptop-1"},
             {"ssh", "unmanaged", "", "uitest"},
             {"task", "running", "managed", ""},
             {"agent", "unmanaged", "manual", ""},
             {"ssh", "unmanaged", "mm", "build-1-remote"}
           ]

    task = Enum.find(report.sessions, &(&1.task_id == "task-123"))
    assert task.actions == "task-send,logs,stop,attach,capture,send"
    assert task.project == "saysure"

    ssh = Enum.find(report.sessions, &(&1.ssh_target == "build-1-remote"))
    assert ssh.actions == "attach,capture,force-probe,adopt"
    assert SessionInventory.probe_requires_force?(ssh)

    standalone_ssh = Enum.find(report.sessions, &(&1.ssh_target == "uitest"))
    assert standalone_ssh.actions == "inspect"

    agent = Enum.find(report.sessions, &(&1.session == "manual"))
    assert agent.actions == "attach,capture,adopt,send"

    assert report.sessions
           |> SessionInventory.filter(type: "ssh")
           |> Enum.map(& &1.ssh_target) == [
             "laptop-1",
             "uitest",
             "build-1-remote"
           ]

    assert SessionInventory.filter(report.sessions, action: "send") == [
             task,
             agent
           ]

    assert SessionInventory.filter(report.sessions, ssh_target: "build-1-remote") == [ssh]
  end

  test "build marks quiet ssh panes as probeable without force" do
    activity_report = %{
      activity: [
        activity(
          host: "local",
          server: "default",
          session: "shell",
          window: 0,
          pane: 0,
          kind: "ssh",
          process_pid: 20,
          current_path: "/Users/developer",
          title: "remote shell",
          active: false
        )
      ],
      errors: []
    }

    ssh_sessions = [
      ssh_session(target: "build", server: "default", session: "shell", window: 0, pane: 0)
    ]

    %{sessions: [session]} = SessionInventory.build(activity_report, ssh_sessions, [])

    assert session.actions == "attach,capture,pane-probe,adopt"
    refute SessionInventory.probe_requires_force?(session)
  end

  test "standalone ssh refs stay unique when target and tty repeat" do
    activity_report = %{activity: [], errors: []}

    ssh_sessions = [
      ssh_session(target: "build-1", server: "", session: "", window: nil, pane: nil, pid: 101),
      ssh_session(target: "build-1", server: "", session: "", window: nil, pane: nil, pid: 102)
    ]

    report = SessionInventory.build(activity_report, ssh_sessions, [])
    refs = Enum.map(report.sessions, & &1.ref)

    assert length(refs) == 2
    assert Enum.uniq(refs) == refs
    assert Enum.map(report.sessions, & &1.ssh_target) == ["build-1", "build-1"]
  end

  test "commands are redacted after stable refs are assigned" do
    activity_report = %{activity: [], errors: []}

    ssh_sessions = [
      ssh_session(
        target: "build-1",
        server: "",
        session: "",
        window: nil,
        pane: nil,
        pid: 101,
        command: "ssh build-1 OPENAI_API_KEY=sk-test --password blade-value"
      ),
      ssh_session(
        target: "build-1",
        server: "",
        session: "",
        window: nil,
        pane: nil,
        pid: 102,
        command: "ssh build-1 OPENAI_API_KEY=sk-other --password dagger"
      )
    ]

    report = SessionInventory.build(activity_report, ssh_sessions, [])

    assert Enum.uniq(Enum.map(report.sessions, & &1.ref)) == Enum.map(report.sessions, & &1.ref)
    assert Enum.all?(report.sessions, &String.contains?(&1.command, "OPENAI_API_KEY=<redacted>"))
    assert Enum.all?(report.sessions, &String.contains?(&1.command, "--password <redacted>"))
    refute Enum.any?(report.sessions, &String.contains?(&1.command, "sk-test"))
    refute Enum.any?(report.sessions, &String.contains?(&1.command, "sk-other"))
    refute Enum.any?(report.sessions, &String.contains?(&1.command, "blade-value"))
    refute Enum.any?(report.sessions, &String.contains?(&1.command, "dagger"))
  end

  test "process-only agents are stream adoption candidates" do
    activity_report = %{
      activity: [
        activity(
          host: "local",
          server: "",
          session: "",
          window: nil,
          pane: nil,
          kind: "codex",
          process_pid: 42,
          current_path: ""
        )
      ],
      errors: []
    }

    %{sessions: [session]} = SessionInventory.build(activity_report, [], [])

    assert session.type == "agent"
    assert session.actions == "inspect,stream-adopt"
  end

  test "process-only agent helpers stay inspectable but are not stream adoption candidates" do
    activity_report = %{
      activity: [
        activity(
          host: "local",
          server: "",
          session: "",
          window: nil,
          pane: nil,
          kind: "codex",
          process_role: "mcp",
          process_pid: 42,
          process_command: "SkyComputerUseClient mcp",
          current_path: ""
        )
      ],
      errors: []
    }

    %{sessions: [session]} = SessionInventory.build(activity_report, [], [])

    assert session.type == "agent"
    assert session.process_role == "mcp"
    assert session.actions == "inspect"
  end

  test "process-only agents with resume context are resume adoption candidates" do
    activity_report = %{
      activity: [
        activity(
          host: "remote",
          transport: "ssh",
          server: "",
          session: "",
          window: nil,
          pane: nil,
          kind: "claude",
          process_role: "acp",
          resume_available: true,
          resume_ref: "resume-abcd1234ef",
          zed_workspace: "workspace-10",
          process_pid: 42,
          current_path: ""
        )
      ],
      errors: []
    }

    %{sessions: [session]} = SessionInventory.build(activity_report, [], [])

    assert session.type == "agent"
    assert session.process_role == "acp"
    assert session.resume_available
    assert session.resume_ref == "resume-abcd1234ef"
    assert session.zed_workspace == "workspace-10"
    assert session.actions == "inspect,resume-adopt"
  end

  test "process-only agent refs stay unique when tty is unknown" do
    activity_report = %{
      activity: [
        activity(
          host: "local",
          server: "",
          session: "",
          window: nil,
          pane: nil,
          tty: "??",
          kind: "codex",
          process_pid: 42,
          current_path: ""
        ),
        activity(
          host: "local",
          server: "",
          session: "",
          window: nil,
          pane: nil,
          tty: "??",
          kind: "codex",
          process_pid: 43,
          current_path: ""
        )
      ],
      errors: []
    }

    report = SessionInventory.build(activity_report, [], [])
    refs = Enum.map(report.sessions, & &1.ref)

    assert length(refs) == 2
    assert Enum.uniq(refs) == refs
  end

  test "build does not expose pane probes for SSH panes running agent UIs" do
    activity_report = %{
      activity: [
        activity(
          host: "local",
          server: "default",
          session: "remote-agent",
          window: 0,
          pane: 0,
          kind: "ssh",
          process_pid: 20,
          current_path: "/Users/developer",
          title: "✳ Claude Code"
        )
      ],
      errors: []
    }

    ssh_sessions = [
      ssh_session(target: "build", server: "default", session: "remote-agent", window: 0, pane: 0)
    ]

    %{sessions: [session]} = SessionInventory.build(activity_report, ssh_sessions, [])

    assert session.actions == "attach,capture,adopt,send"
    assert SessionInventory.probe_requires_force?(session)
    assert SessionInventory.probe_runs_in_agent_ui?(session)
  end

  test "probe_requires_force gates foreground ssh candidates without activity metadata" do
    foreground =
      ssh_session(target: "build", server: "default", session: "shell", window: 0, pane: 0)

    background = %{foreground | stat: "S"}

    assert SessionInventory.probe_requires_force?(Map.put(foreground, :type, "ssh"))
    refute SessionInventory.probe_requires_force?(Map.put(background, :type, "ssh"))
  end

  defp activity(attrs) do
    %{
      host: Keyword.fetch!(attrs, :host),
      transport: Keyword.get(attrs, :transport, "local"),
      server: Keyword.fetch!(attrs, :server),
      session: Keyword.fetch!(attrs, :session),
      window: Keyword.fetch!(attrs, :window),
      pane: Keyword.fetch!(attrs, :pane),
      tty: Keyword.get(attrs, :tty, "/dev/ttys001"),
      active: Keyword.get(attrs, :active, true),
      kind: Keyword.fetch!(attrs, :kind),
      pane_kind: Keyword.fetch!(attrs, :kind),
      pane_command: Keyword.fetch!(attrs, :kind),
      process_role: Keyword.get(attrs, :process_role, ""),
      resume_available: Keyword.get(attrs, :resume_available, false),
      resume_ref: Keyword.get(attrs, :resume_ref, ""),
      zed_workspace: Keyword.get(attrs, :zed_workspace, ""),
      process_pid: Keyword.fetch!(attrs, :process_pid),
      process_stat: Keyword.get(attrs, :process_stat, "S+"),
      process_command: Keyword.get(attrs, :process_command, Keyword.fetch!(attrs, :kind)),
      current_path: Keyword.fetch!(attrs, :current_path),
      title: Keyword.get(attrs, :title, "")
    }
  end

  defp ssh_session(attrs) do
    %{
      role: "outbound",
      target: Keyword.fetch!(attrs, :target),
      registered_host: Keyword.get(attrs, :registered_host, ""),
      pid: Keyword.get(attrs, :pid, 100),
      stat: Keyword.get(attrs, :stat, "S+"),
      tty: Keyword.get(attrs, :tty, "ttys001"),
      command: Keyword.get(attrs, :command, "ssh #{Keyword.fetch!(attrs, :target)}"),
      server: Keyword.fetch!(attrs, :server),
      session: Keyword.fetch!(attrs, :session),
      window: Keyword.fetch!(attrs, :window),
      pane: Keyword.fetch!(attrs, :pane),
      current_path: Keyword.get(attrs, :current_path, ""),
      title: Keyword.get(attrs, :title, "")
    }
  end
end
