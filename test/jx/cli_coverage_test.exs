defmodule JX.CLICoverageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JX.CLI
  alias JX.Workspace

  test "all focused help groups render" do
    groups =
      ~w(approvals actions agents runners assignments call ci dashboard delegate devide events fanout host hosts leases meet modes monitor next notifications orchestrator policy portfolio promote queue project repo sessions tmux tui wake watch)

    for group <- groups do
      output = cli_output(["help", group])
      assert output =~ "jx help #{group}"
    end
  end

  test "registry project session task and tmux commands run through CLI" do
    %{host: host, project: project} = register_workspace()

    assert cli_output(["host", "ls"]) =~ host

    assert cli_output(["host", "doctor", host, "--agent", "codex", "--transport", "native"]) =~
             "doctor"

    assert cli_output(["hosts", "doctor", "--agent", "codex", "--transport", "native"]) =~
             "host #{host}"

    assert cli_json(["project", "ls", "--json"])["projects"]

    assert cli_json(["repo", "doctor", project, "--host", host, "--json"])["repo_doctor"][
             "project"
           ] == project

    assert cli_json(["repo", "gate", project, "--host", host, "--json"])["repo_gate"] == %{
             "project" => project,
             "eligible" => false,
             "status" => "blocked",
             "reasons" => ["push_not_verified"],
             "required_fixes" => ["Restore GitHub auth and rerun repo doctor."],
             "summary" => %{"allowed" => 0, "blocked" => 1, "total" => 1},
             "instances" => [
               %{
                 "host" => host,
                 "repo_path" => "/srv/repos/saysure",
                 "eligible" => false,
                 "status" => "blocked",
                 "reasons" => ["push_not_verified"],
                 "required_fixes" => ["Restore GitHub auth and rerun repo doctor."],
                 "reconciliation_status" => "reconciled",
                 "trust_status" => "trusted",
                 "confidence" => "high",
                 "drift_status" => "none",
                 "auth" => %{
                   "fetch_allowed" => "ok",
                   "push_allowed" => "unknown",
                   "api_allowed" => "unknown"
                 }
               }
             ]
           }

    assert cli_json(["project", "gate", project, "--json"])["project_gate"] == %{
             "project" => project,
             "eligible" => false,
             "status" => "blocked",
             "reasons" => ["#{host}:push_not_verified"],
             "required_fixes" => ["#{host}: Restore GitHub auth and rerun repo doctor."],
             "hosts" => [
               %{
                 "host" => host,
                 "repo_path" => "/srv/repos/saysure",
                 "eligible" => false,
                 "status" => "blocked",
                 "reasons" => ["push_not_verified"],
                 "required_fixes" => ["Restore GitHub auth and rerun repo doctor."],
                 "reconciliation_status" => "reconciled",
                 "trust_status" => "trusted",
                 "confidence" => "high",
                 "drift_status" => "none",
                 "auth" => %{
                   "fetch_allowed" => "ok",
                   "push_allowed" => "unknown",
                   "api_allowed" => "unknown"
                 }
               }
             ]
           }

    assert cli_json([
             "promote",
             "preflight",
             project,
             "--from",
             "develop",
             "--to",
             "master",
             "--json"
           ])["promotion_preflight"] == %{
             "project" => project,
             "source_branch" => "develop",
             "target_branch" => "master",
             "eligible" => false,
             "status" => "blocked",
             "reasons" => ["#{host}:push_not_verified"],
             "required_fixes" => ["#{host}: Restore GitHub auth and rerun repo doctor."],
             "project_gate" => %{
               "project" => project,
               "eligible" => false,
               "status" => "blocked",
               "reasons" => ["#{host}:push_not_verified"],
               "required_fixes" => ["#{host}: Restore GitHub auth and rerun repo doctor."],
               "hosts" => [
                 %{
                   "host" => host,
                   "repo_path" => "/srv/repos/saysure",
                   "eligible" => false,
                   "status" => "blocked",
                   "reasons" => ["push_not_verified"],
                   "required_fixes" => ["Restore GitHub auth and rerun repo doctor."],
                   "reconciliation_status" => "reconciled",
                   "trust_status" => "trusted",
                   "confidence" => "high",
                   "drift_status" => "none",
                   "auth" => %{
                     "fetch_allowed" => "ok",
                     "push_allowed" => "unknown",
                     "api_allowed" => "unknown"
                   }
                 }
               ]
             }
           }

    promotion =
      cli_error_json([
        "promote",
        "run",
        project,
        "--from",
        "develop",
        "--to",
        "master",
        "--json"
      ])["promotion"]

    assert Map.keys(promotion) |> Enum.sort() ==
             ~w(actions errors preflight project source_branch status target_branch)

    assert promotion["project"] == project
    assert promotion["source_branch"] == "develop"
    assert promotion["target_branch"] == "master"
    assert promotion["status"] == "blocked"
    assert promotion["actions"] == []
    assert promotion["errors"] == []
    assert promotion["preflight"]["status"] == "blocked"
    assert promotion["preflight"]["reasons"] == ["#{host}:push_not_verified"]

    assert get_in(cli_json(["project", "audit", project, "--host", host, "--json"]), [
             "project_audit",
             "project"
           ]) == project

    assert cli_json(["project", "brief", project, "--host", host, "--no-observe", "--json"])

    assign_output =
      cli_output([
        "assign",
        project,
        "inspect CLI coverage seams",
        "--host",
        host,
        "--agent",
        "codex",
        "--goal-objective",
        "cover CLI assign goal line"
      ])

    [_, task_id] = Regex.run(~r/task (task-[a-f0-9]+) assigned/, assign_output)

    assert cli_output(["status"]) =~ task_id
    assert cli_output(["task", "send", task_id, "report status", "--no-enter"]) =~ "directive"
    assert cli_output(["logs", task_id, "-n", "5"]) == ""
    assert cli_output(["attach", task_id]) == ""
    assert cli_output(["stop", task_id]) =~ "stopped"

    assert cli_output(["tmux", "ls", host]) =~ "jx_saysure"
    assert cli_output(["tmux", "panes", host]) =~ "codex"

    assert cli_output(["tmux", "capture", host, "jx_saysure_task_deadbeef_codex", "-n", "5"]) =~
             "recent pane output"

    assert cli_output([
             "tmux",
             "send",
             host,
             "jx_saysure_task_deadbeef_codex",
             "hello",
             "--no-enter"
           ]) =~ "directive"

    assert cli_output(["tmux", "attach", host, "jx_saysure_task_deadbeef_codex"]) == ""
    assert cli_output(["tmux", "stop", host, "jx_saysure_task_deadbeef_codex"]) =~ "stopped"

    ssh_ls_output = cli_output(["ssh", "ls"])
    assert ssh_ls_output =~ "ROLE" or ssh_ls_output =~ "no ssh sessions"
    pane_probe_output = cli_output(["ssh", "pane-probe", "--all", "--dry-run"])
    assert pane_probe_output =~ "SSH_TARGET" or pane_probe_output =~ "no ssh panes"
    process_output = cli_output(["process", "ls", "--kind", "codex"])
    assert process_output =~ "codex" or process_output =~ "no processes"
  end

  test "session portfolio monitor and orchestration commands run through CLI" do
    %{host: host, project: project} = register_workspace()

    snapshot =
      cli_json([
        "sessions",
        "snapshot",
        "--host",
        host,
        "--type",
        "agent",
        "--save",
        "--json"
      ])

    [%{"ref" => ref}] = snapshot["sessions"]

    assert cli_json(["session", "inspect", ref, "--json"])["ref"] == ref
    assert cli_output(["session", "capture", ref, "-n", "5"]) =~ "recent pane output"

    assert cli_output(["session", "mark", ref, "--mode", "managed", "--project", project]) =~
             "marked managed"

    assert cli_json([
             "session",
             "profile",
             ref,
             "--summary",
             "CLI profile",
             "--objective",
             "Cover CLI session profile",
             "--expect",
             "profile renders",
             "--next-prompt",
             "continue",
             "--prompt-status",
             "ready",
             "--risk",
             "normal",
             "--lifecycle",
             "active",
             "--no-observe",
             "--json"
           ])

    assert cli_output(["session", "send", ref, "continue", "--no-enter"]) =~ "directive"
    assert cli_json(["session", "key", ref, "C-u", "--no-enter", "--json"])["keys"] == "C-u"
    assert {:error, _reason} = CLI.run(["session", "probe", ref, "--json"])

    assert cli_json(["sessions", "--host", host, "--type", "agent", "--json"])["sessions"]
    assert cli_json(["sessions", "summary", "--host", host, "--type", "agent", "--json"])
    assert cli_json(["sessions", "observe", "--host", host, "--type", "agent", "--json"])
    assert cli_json(["sessions", "changed", "--json"])

    assert cli_json([
             "sessions",
             "ready",
             "--host",
             host,
             "--type",
             "agent",
             "--no-observe",
             "--json"
           ])

    assert cli_json([
             "sessions",
             "queues",
             "--host",
             host,
             "--type",
             "agent",
             "--no-observe",
             "--json"
           ])

    assert cli_json([
             "sessions",
             "dossiers",
             "--host",
             host,
             "--type",
             "agent",
             "--no-observe",
             "--json"
           ])

    assert cli_json([
             "sessions",
             "profiles",
             "--host",
             host,
             "--type",
             "agent",
             "--no-observe",
             "--json"
           ])

    assert cli_json(["sessions", "reconcile", "--host", host, "--type", "agent", "--json"])
    assert cli_json(["sessions", "recover", "--host", host, "--type", "agent", "--json"])
    assert cli_json(["sessions", "history", "--ref", ref, "--json"])
    assert cli_json(["sessions", "changes", "--ref", ref, "--json"])
    assert cli_json(["sessions", "stale", "--ref", ref, "--seconds", "1", "--json"])

    assert cli_json([
             "sessions",
             "broadcast",
             "stand by",
             "--host",
             host,
             "--type",
             "agent",
             "--json"
           ])

    assert cli_json(["sessions", "remote", "--json"])
    assert cli_json(["sessions", "remote", "--probe", "--json"])

    assert cli_json(["work", "ls", "--host", host, "--type", "agent", "--json"])
    assert cli_output(["discover", "--host", host]) =~ "SESSION"
    assert cli_output(["activity", "--host", host, "--all-processes"]) =~ "codex"
    assert cli_json(["portfolio", "summary", "--host", host, "--no-observe", "--json"])
    assert cli_json(["call", "brief", "--host", host, "--observe", "--json"])
    assert cli_json(["next", "--host", host, "--no-observe", "--json"])
    assert cli_json(["operate", "--host", host, "--type", "agent", "--json"])
    assert cli_json(["manage", "--host", host, "--type", "agent", "--iterations", "1", "--json"])

    assert cli_json(["monitor", "scan", "--host", host, "--type", "agent", "--json"])
    assert cli_json(["monitor", "status", "--consumer", "cli-coverage", "--json"])
    assert cli_json(["orchestrate", "step", "--host", host, "--type", "agent", "--json"])
    assert cli_json(["orchestrator", "health", "--json"])
    assert cli_json(["orchestrator", "heartbeats", "--json"])

    assert cli_json([
             "orchestrator",
             "inbox",
             "--host",
             host,
             "--type",
             "agent",
             "--no-observe",
             "--json"
           ])

    assert cli_json(["orchestrator", "review", ref, "--no-observe", "--json"])
    assert cli_json(["orchestrator", "decide", ref, "--hold", "covered", "--json"])

    assert cli_output(["session", "unmark", ref]) =~ "unmarked"
  end

  test "watch wake CI delegation and notification commands run through CLI" do
    %{host: host, project: project} = register_workspace()

    {:ok, %{sessions: [%{ref: ref}]}} =
      Workspace.snapshot_sessions(host_name: host, type: "agent")

    wake = cli_json(["wake", "--message", "operator ping", "--project", project, "--json"])
    assert wake["wake_id"]

    trigger =
      cli_json([
        "wake",
        "add",
        "--message",
        "scheduled ping",
        "--in",
        "1s",
        "--project",
        project,
        "--json"
      ])

    trigger_id = get_in(trigger, ["trigger", "trigger_id"])
    assert trigger_id
    assert cli_json(["wake", "ls", "--project", project, "--json"])["triggers"]
    assert cli_json(["wake", "run-due", "--limit", "5", "--json"])

    assert cli_json(["wake", "remove", trigger_id, "--json"])["trigger"]["status"] ==
             "cancelled"

    ci_watch =
      cli_json([
        "ci",
        "watch",
        "42",
        "--repo",
        "owner/repo",
        "--ref",
        ref,
        "--project",
        project,
        "--mode",
        "notify",
        "--goal",
        "watch checks",
        "--json"
      ])

    ci_watch_id = ci_watch["watch_id"]
    assert ci_watch_id
    assert cli_json(["ci", "watches", "--project", project, "--json"])["ci_watches"]
    assert {:error, :ci_watch_not_found} = CLI.run(["ci", "review", "missing-watch", "--json"])
    assert cli_json(["ci", "cancel", ci_watch_id, "--summary", "covered", "--json"])

    handoff =
      cli_json([
        "call",
        "handoff",
        "add",
        "--summary",
        "Turn call notes into tracked work",
        "--title",
        "CLI handoff",
        "--project",
        project,
        "--ref",
        ref,
        "--decision",
        "continue",
        "--follow-up",
        "report",
        "--no-brief",
        "--json"
      ])

    handoff_id = handoff["handoff_id"]
    assert handoff_id
    assert cli_json(["call", "handoff", "ls", "--project", project, "--json"])["handoffs"]

    assert cli_json([
             "call",
             "handoff",
             "apply",
             handoff_id,
             "--action",
             "hold",
             "--ref",
             ref,
             "--reason",
             "covered",
             "--json"
           ])

    assert cli_json(["call", "handoff", "close", handoff_id, "--summary", "closed", "--json"])

    delegation =
      cli_json([
        "delegate",
        "create",
        "--title",
        "CLI delegation",
        "--brief",
        "Cover delegation CLI",
        "--project",
        project,
        "--ref",
        ref,
        "--context",
        "coverage",
        "--constraint",
        "deterministic",
        "--acceptance",
        "passes",
        "--verify",
        "mix test",
        "--write",
        "test/jx/cli_coverage_test.exs",
        "--json"
      ])

    delegation_id = delegation["delegation_id"]
    assert delegation_id
    assert cli_json(["delegate", "ls", "--project", project, "--json"])["delegations"]
    assert cli_json(["delegate", "brief", delegation_id, "--json"])["brief"]
    assert cli_json(["delegate", "lint", delegation_id, "--json"])

    assert cli_json([
             "delegate",
             "evidence",
             delegation_id,
             "--command",
             "mix test",
             "--cwd",
             "/repo",
             "--exit",
             "0",
             "--kind",
             "focused",
             "--output",
             "pass",
             "--json"
           ])

    assert cli_json([
             "delegate",
             "complete",
             delegation_id,
             "--summary",
             "done",
             "--verify",
             "mix test",
             "--artifact",
             "test/jx/cli_coverage_test.exs",
             "--json"
           ])

    assert cli_json(["delegate", "review", delegation_id, "--json"])
    assert cli_json(["delegate", "reviews", "--project", project, "--json"])["reviews"]

    assert cli_json([
             "delegate",
             "decide",
             delegation_id,
             "--decision",
             "hold",
             "--summary",
             "covered",
             "--json"
           ])

    assert cli_json(["delegate", "timing", "--project", project, "--json"])["samples_total"] == 1
    assert cli_json(["notifications", "ls", "--project", project, "--json"])["notifications"]
    assert cli_json(["notifications", "ack", "--all", "--project", project, "--json"])
    assert cli_json(["notifications", "compact", "--project", project, "--json"])
    assert cli_json(["events", "ls", "--ref", ref, "--json"])
    assert cli_json(["events", "unread", "--consumer", "cli-events", "--json"])
    assert cli_json(["events", "ack", "--consumer", "cli-events", "--latest", "--json"])
    assert cli_json(["events", "cursor", "--consumer", "cli-events", "--json"])
    assert cli_json(["events", "check", "--json"])
  end

  test "control-plane list and lifecycle commands run through CLI" do
    %{host: host} = register_workspace()

    assert cli_json([
             "agents",
             "register",
             "agent-cli",
             "--name",
             "CLI Agent",
             "--capability",
             "elixir",
             "--workspace",
             "workspace-cli",
             "--json"
           ])

    assert cli_json(["agents", "heartbeat", "agent-cli", "--json"])
    assert cli_json(["agents", "ls", "--status", "all", "--json"])["agents"]

    assert cli_json([
             "runners",
             "register",
             "runner-cli",
             "--agent",
             "agent-cli",
             "--host",
             host,
             "--capability",
             "elixir",
             "--workspace",
             "workspace-cli",
             "--json"
           ])

    assert cli_json(["runners", "heartbeat", "runner-cli", "--json"])
    assert cli_json(["runners", "show", "runner-cli", "--json"])["runner_id"] == "runner-cli"
    assert cli_json(["runners", "ls", "--status", "all", "--json"])["runners"]

    lease =
      cli_json([
        "leases",
        "acquire",
        "workspace",
        "workspace-cli",
        "--owner",
        "agent-cli",
        "--reason",
        "coverage",
        "--json"
      ])

    lease_id = lease["lease_id"]
    assert lease_id
    assert cli_json(["leases", "ls", "--owner", "agent-cli", "--json"])["leases"]

    reassigned_lease =
      cli_json([
        "leases",
        "reassign",
        "workspace",
        "workspace-cli",
        "--owner",
        "runner-cli",
        "--json"
      ])

    assert cli_json([
             "leases",
             "release",
             reassigned_lease["lease_id"],
             "--owner",
             "runner-cli",
             "--json"
           ])

    assert cli_json(["queue", "ls", "--sort", "urgency", "--json"])
    assert cli_json(["queue", "workspace", "workspace-cli", "--json"])
    assert cli_json(["queue", "rebuild", "--json"])
    assert cli_json(["timeline", "workspace", "workspace-cli", "--json"])
    assert cli_json(["actions", "ls", "--json"])["actions"]
    assert cli_json(["approvals", "ls", "--status", "all", "--json"])["approvals"]
    assert cli_json(["operations", "ls", "--json"])["operations"]
    directives_output = cli_output(["directives", "ls"])
    assert directives_output =~ "DIRECTIVE" or directives_output =~ "no directives"
    assert cli_json(["policy", "overview", "--json"])["safety_tiers"]
    assert cli_json(["policy", "check", "push", "--json"])["decision"] == "allowed"
    assert cli_json(["controls", "ls", "--json"])["controls"]
    assert cli_json(["remote", "ls", "--json"])["remote_sessions"]

    assert cli_json([
             "operator",
             "profile",
             "set",
             "--name",
             "CLI Operator",
             "--preferences",
             "concise",
             "--json"
           ])

    assert cli_json(["operator", "profile", "--json"])["operator"]
    assert cli_json(["sessions", "ls", "--status", "all", "--json"])["sessions"]
    assert cli_json(["sessions", "expire", "--json"])
  end

  test "Meet CLI planning commands run without external services" do
    %{project: project} = register_workspace()
    dir = Path.join(System.tmp_dir!(), "jx-meet-cli-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    assert cli_json(["meet", "plugin", "--json"])["id"] == "google_meet"

    assert cli_json([
             "meet",
             "auth",
             "configure",
             "--profile",
             "cli",
             "--email",
             "cli@example.test",
             "--client-id",
             "client-id",
             "--client-secret-env",
             "GOOGLE_SECRET",
             "--json"
           ])

    assert cli_json(["meet", "auth", "status", "--profile", "cli", "--json"])["profiles"]

    assert cli_json([
             "meet",
             "auth",
             "url",
             "--profile",
             "cli",
             "--login-hint",
             "cli@example.test",
             "--json"
           ])["auth_url"]

    session =
      cli_json([
        "meet",
        "session",
        "create",
        "--meeting",
        "https://meet.google.com/abc-mnop-xyz",
        "--title",
        "CLI Meet",
        "--project",
        project,
        "--ref",
        "meet-ref",
        "--auth-profile",
        "cli",
        "--artifact-dir",
        dir,
        "--no-handoff",
        "--json"
      ])

    session_id = session["sessions"] |> hd() |> Map.fetch!("session_id")
    assert session_id

    assert cli_json(["meet", "session", "ls", "--project", project, "--json"])["sessions"]

    assert cli_json(["meet", "session", "plan", session_id, "--json"])["session"]["session_id"] ==
             session_id

    assert cli_json(["meet", "realtime", "plan", session_id, "--json"])["session"]["session_id"] ==
             session_id

    assert cli_json(["meet", "realtime", "start", session_id, "--json"])["voice_loop"]["status"] ==
             "planned"

    assert cli_json([
             "meet",
             "realtime",
             "consult",
             session_id,
             "--transcript",
             "We decided to keep the test deterministic.",
             "--summary",
             "Deterministic test",
             "--project",
             project,
             "--ref",
             "meet-ref",
             "--json"
           ])["handoff"]["handoff_id"]

    assert cli_json(["meet", "export", session_id, "--dir", dir, "--format", "json", "--json"])[
             "files"
           ]
  end

  test "non-json renderers cover operator-facing command surfaces" do
    %{host: host, project: project} = register_workspace()

    snapshot =
      cli_json([
        "sessions",
        "snapshot",
        "--host",
        host,
        "--type",
        "agent",
        "--save",
        "--json"
      ])

    [%{"ref" => ref}] = snapshot["sessions"]

    cli_json([
      "session",
      "profile",
      ref,
      "--summary",
      "Text profile",
      "--objective",
      "Cover text renderers",
      "--next-prompt",
      "continue",
      "--prompt-status",
      "ready",
      "--json"
    ])

    watch =
      cli_json([
        "watch",
        "add",
        ref,
        "--goal",
        "text watch",
        "--success",
        "done",
        "--mode",
        "notify",
        "--json"
      ])

    watch_id = watch["watch_id"]

    wake_trigger =
      cli_json([
        "wake",
        "add",
        "--message",
        "text trigger",
        "--in",
        "1s",
        "--project",
        project,
        "--json"
      ])

    trigger_id = get_in(wake_trigger, ["trigger", "trigger_id"])

    ci_watch =
      cli_json([
        "ci",
        "watch",
        "77",
        "--repo",
        "owner/repo",
        "--ref",
        ref,
        "--project",
        project,
        "--mode",
        "notify",
        "--json"
      ])

    ci_watch_id = ci_watch["watch_id"]

    handoff =
      cli_json([
        "call",
        "handoff",
        "add",
        "--summary",
        "Text handoff",
        "--project",
        project,
        "--ref",
        ref,
        "--no-brief",
        "--json"
      ])

    handoff_id = handoff["handoff_id"]

    delegation =
      cli_json([
        "delegate",
        "create",
        "--title",
        "Text delegation",
        "--brief",
        "Cover text delegation renderers",
        "--project",
        project,
        "--ref",
        ref,
        "--context",
        "coverage",
        "--constraint",
        "deterministic",
        "--acceptance",
        "renders",
        "--verify",
        "mix test",
        "--write",
        "test/jx/cli_coverage_test.exs",
        "--json"
      ])

    delegation_id = delegation["delegation_id"]

    cli_json([
      "agents",
      "register",
      "agent-text",
      "--name",
      "Text Agent",
      "--workspace",
      "workspace-text",
      "--json"
    ])

    cli_json([
      "runners",
      "register",
      "runner-text",
      "--agent",
      "agent-text",
      "--host",
      host,
      "--workspace",
      "workspace-text",
      "--json"
    ])

    lease =
      cli_json([
        "leases",
        "acquire",
        "workspace",
        "workspace-text",
        "--owner",
        "agent-text",
        "--json"
      ])

    lease_id = lease["lease_id"]

    meet_dir = Path.join(System.tmp_dir!(), "jx-meet-text-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(meet_dir) end)

    cli_json([
      "meet",
      "auth",
      "configure",
      "--profile",
      "text",
      "--client-id",
      "client-id",
      "--json"
    ])

    meet_session =
      cli_json([
        "meet",
        "session",
        "create",
        "--meeting",
        "https://meet.google.com/def-ghij-klm",
        "--title",
        "Text Meet",
        "--project",
        project,
        "--auth-profile",
        "text",
        "--artifact-dir",
        meet_dir,
        "--no-handoff",
        "--json"
      ])

    meet_session_id = meet_session["sessions"] |> hd() |> Map.fetch!("session_id")

    text_commands = [
      ["version"],
      ["modes"],
      ["modes", "playbook", "tui"],
      ["project", "ls"],
      ["project", "audit", project, "--host", host],
      ["project", "brief", project, "--host", host, "--no-observe"],
      ["portfolio", "summary", "--host", host, "--no-observe"],
      ["call", "brief", "--host", host, "--no-observe"],
      ["next", "--host", host, "--no-observe"],
      ["tui", "plan"],
      ["tui", "snapshot", "--host", host, "--no-observe"],
      ["tui", "panel", "--host", host, "--no-observe", "--iterations", "1"],
      [
        "tui",
        "watch",
        "--host",
        host,
        "--no-observe",
        "--iterations",
        "1",
        "--interval-ms",
        "1",
        "--no-clear"
      ],
      ["wake", "--message", "text wake", "--project", project],
      ["wake", "ls", "--project", project],
      ["wake", "run-due", "--limit", "5"],
      ["wake", "remove", trigger_id],
      ["ci", "watches", "--project", project],
      ["ci", "cancel", ci_watch_id, "--summary", "text done"],
      ["call", "handoff", "ls", "--project", project],
      [
        "call",
        "handoff",
        "apply",
        handoff_id,
        "--action",
        "hold",
        "--ref",
        ref,
        "--reason",
        "text"
      ],
      ["call", "handoff", "close", handoff_id, "--summary", "closed"],
      ["delegate", "ls", "--project", project],
      ["delegate", "brief", delegation_id],
      ["delegate", "lint", delegation_id],
      [
        "delegate",
        "evidence",
        delegation_id,
        "--command",
        "mix test",
        "--cwd",
        "/repo",
        "--exit",
        "0"
      ],
      ["delegate", "complete", delegation_id, "--summary", "done", "--verify", "mix test"],
      ["delegate", "review", delegation_id],
      ["delegate", "reviews", "--project", project],
      ["delegate", "decide", delegation_id, "--decision", "hold", "--summary", "text hold"],
      ["delegate", "timing", "--project", project],
      ["sessions", "--host", host, "--type", "agent"],
      ["sessions", "summary", "--host", host, "--type", "agent"],
      ["sessions", "observe", "--host", host, "--type", "agent"],
      ["sessions", "changed"],
      ["sessions", "ready", "--host", host, "--type", "agent", "--no-observe"],
      ["sessions", "queues", "--host", host, "--type", "agent", "--no-observe"],
      ["sessions", "dossiers", "--host", host, "--type", "agent", "--no-observe"],
      ["sessions", "profiles", "--host", host, "--type", "agent", "--no-observe"],
      ["sessions", "reconcile", "--host", host, "--type", "agent"],
      ["sessions", "recover", "--host", host, "--type", "agent"],
      ["sessions", "history", "--ref", ref],
      ["sessions", "changes", "--ref", ref],
      ["sessions", "stale", "--ref", ref, "--seconds", "1"],
      ["sessions", "broadcast", "text broadcast", "--host", host, "--type", "agent"],
      ["sessions", "remote"],
      ["session", "inspect", ref],
      ["session", "capture", ref, "-n", "5"],
      ["session", "mark", ref, "--mode", "managed", "--project", project],
      ["session", "send", ref, "text prompt", "--no-enter"],
      ["session", "key", ref, "C-u", "--no-enter"],
      ["session", "unmark", ref],
      ["work", "ls", "--host", host, "--type", "agent"],
      ["operate", "--host", host, "--type", "agent"],
      ["manage", "--host", host, "--type", "agent", "--iterations", "1"],
      ["monitor", "scan", "--host", host, "--type", "agent"],
      ["monitor", "status", "--consumer", "text-consumer"],
      ["orchestrate", "step", "--host", host, "--type", "agent"],
      ["orchestrator", "health"],
      ["orchestrator", "heartbeats"],
      ["orchestrator", "inbox", "--host", host, "--type", "agent", "--no-observe"],
      ["orchestrator", "review", ref, "--no-observe"],
      ["orchestrator", "decide", ref, "--hold", "text"],
      ["events", "ls", "--ref", ref],
      ["events", "unread", "--consumer", "text-consumer"],
      ["events", "ack", "--consumer", "text-consumer", "--latest"],
      ["events", "cursor", "--consumer", "text-consumer"],
      ["events", "check"],
      ["watch", "ls", "--ref", ref],
      ["watch", "review", watch_id, "--no-observe"],
      ["watch", "complete", watch_id, "--summary", "done"],
      ["agents", "ls", "--status", "all"],
      ["runners", "show", "runner-text"],
      ["runners", "ls", "--status", "all"],
      ["leases", "ls", "--owner", "agent-text"],
      ["leases", "release", lease_id, "--owner", "agent-text"],
      ["queue", "ls"],
      ["queue", "workspace", "workspace-text"],
      ["queue", "rebuild"],
      ["dashboard"],
      ["dashboard", "workspace", "workspace-text"],
      ["dashboard", "runner", "runner-text"],
      ["timeline", "workspace", "workspace-text"],
      ["actions", "ls"],
      ["approvals", "ls", "--status", "all"],
      ["operations", "ls"],
      ["directives", "ls"],
      ["notifications", "ls", "--project", project],
      ["notifications", "ack", "--all", "--project", project],
      ["notifications", "compact", "--project", project],
      ["policy", "overview"],
      ["policy", "check", "push"],
      ["policy", "tiers"],
      ["controls", "ls"],
      ["operator", "profile", "set", "--name", "Text Operator", "--preferences", "concise"],
      ["operator", "profile"],
      ["remote", "ls"],
      ["meet", "plugin"],
      ["meet", "auth", "status", "--profile", "text"],
      ["meet", "auth", "url", "--profile", "text"],
      ["meet", "session", "ls", "--project", project],
      ["meet", "session", "plan", meet_session_id],
      ["meet", "realtime", "plan", meet_session_id],
      ["meet", "realtime", "start", meet_session_id],
      [
        "meet",
        "realtime",
        "consult",
        meet_session_id,
        "--transcript",
        "Text consult transcript",
        "--summary",
        "Text consult",
        "--project",
        project
      ],
      ["meet", "export", meet_session_id, "--dir", meet_dir, "--format", "json"]
    ]

    for args <- text_commands do
      assert is_binary(cli_output(args)), "expected text output from #{inspect(args)}"
    end
  end

  test "fanout and orchestrator lifecycle command renderers run through CLI" do
    fanout_root =
      Path.join(System.tmp_dir!(), "jx-cli-fanout-#{System.unique_integer([:positive])}")

    File.mkdir_p!(fanout_root)
    on_exit(fn -> File.rm_rf(fanout_root) end)

    coverage_file = Path.join(fanout_root, "coverage.csv")
    File.write!(coverage_file, "lib/one/api/token.ex,42,high\n")

    fanout_plan =
      cli_json([
        "fanout",
        "plan",
        "coverage-dynamic",
        "--baseline",
        "53907e03",
        "--root",
        fanout_root,
        "--run-id",
        "cli-fanout",
        "--coverage-file",
        coverage_file,
        "--host-count",
        "1",
        "--host",
        "localhost=/repo,/worktrees,",
        "--json"
      ])

    assert fanout_plan["run_id"] == "cli-fanout"
    assert fanout_plan["assignment_ids"] == ["coverage-01"]
    assert cli_output(["fanout", "status", "cli-fanout", "--root", fanout_root]) =~ "coverage-01"

    assert cli_json(["fanout", "status", "cli-fanout", "--root", fanout_root, "--json"])[
             "counts"
           ]["planned"] == 1

    {tmp, log_path} = install_fake_tmux!()

    daemon_args = [
      "--session",
      "jx-orchestrator-cli",
      "--server",
      "jx",
      "--log",
      log_path
    ]

    assert cli_json(["orchestrator", "status"] ++ daemon_args ++ ["--json"])["running"] ==
             false

    start_output =
      cli_output(
        ["orchestrator", "start"] ++
          daemon_args ++ ["--dry-run", "--replace", "--interval-ms", "1000"]
      )

    assert start_output =~ "orchestrator"

    assert cli_json(["orchestrator", "status"] ++ daemon_args ++ ["--json"])["running"] ==
             true

    File.write!(log_path, "one\ntwo\nthree")

    assert cli_output(["orchestrator", "logs"] ++ daemon_args ++ ["-n", "2"]) == "two\nthree\n"

    assert cli_json(["orchestrator", "logs"] ++ daemon_args ++ ["-n", "1", "--json"])[
             "output"
           ] == "three"

    assert cli_json(["orchestrator", "stop"] ++ daemon_args ++ ["--json"])["stopped"] == true

    assert File.dir?(tmp)
  end

  test "usage and validation errors cover malformed CLI surfaces" do
    assert cli_output([]) =~ "jx"
    assert cli_output(["--help"]) =~ "jx"
    assert cli_output(["-h"]) =~ "jx"
    assert cli_output(["help"]) =~ "jx"
    assert cli_error(["help", "too", "many"]) =~ "usage: jx help"

    assert cli_error(["promote", "preflight", "project", "--to", "master"]) =~
             "usage: jx promote preflight"

    assert cli_error(["promote", "preflight", "project", "--from", "develop"]) =~
             "usage: jx promote preflight"

    assert cli_error(["promote", "run", "project", "--to", "master"]) =~
             "usage: jx promote run"

    assert cli_error(["promote", "run", "project", "--from", "develop"]) =~
             "usage: jx promote run"

    invalid_commands = [
      ["host"],
      ["host", "doctor"],
      ["hosts"],
      ["repo"],
      ["project"],
      ["promote"],
      ["ci"],
      ["ci", "digest", "not-a-number", "--repo", "o/r"],
      ["ci", "digest", "12"],
      ["ci", "watch", "12", "--repo", "o/r", "--mode", "bad"],
      ["ci", "watches", "--status", "bad"],
      ["portfolio"],
      ["portfolio", "summary", "--n", "0"],
      ["call"],
      ["call", "handoff"],
      ["call", "handoff", "add"],
      ["call", "handoff", "apply", "h", "--action", "bad"],
      ["meet"],
      ["meet", "auth"],
      ["meet", "auth", "configure"],
      ["meet", "auth", "exchange"],
      ["meet", "session"],
      ["meet", "session", "create", "--twilio-mode", "bad"],
      ["meet", "session", "ls", "--status", "bad"],
      ["meet", "session", "join", "s", "--runner", "bad"],
      ["meet", "realtime"],
      ["meet", "realtime", "plan", "s", "--provider", "bad"],
      ["meet", "realtime", "watch", "s", "--iterations", "-1"],
      ["meet", "recover"],
      ["meet", "recover", "--meeting", "bad-code"],
      ["meet", "export", "s", "--format", "bad"],
      ["delegate"],
      ["delegate", "create"],
      ["delegate", "create", "--title", "x", "--brief", "y", "--agent", "bad"],
      ["delegate", "decide", "d", "--decision", "bad"],
      ["delegate", "evidence", "d", "--exit", "-1"],
      ["delegate", "timing", "--target-parallel", "0"],
      ["fanout"],
      ["fanout", "plan", "unknown", "--baseline", "abc"],
      ["fanout", "launch", "missing", "one", "two"],
      ["assign"],
      ["assign", "project", "--agent", "bad"],
      ["orchestrator"],
      ["orchestrator", "start", "--server", "bad server"],
      ["orchestrate"],
      ["orchestrate", "step", "--interval-ms", "0"],
      ["monitor"],
      ["monitor", "scan", "--event-limit", "0"],
      ["events"],
      ["events", "ack"],
      ["events", "ack", "--latest", "--to-id", "4"],
      ["dashboard", "--n", "0"],
      ["dashboard", "workspace", "workspace-text", "--events", "0"],
      ["dashboard", "runner", "runner-text", "--n", "0"],
      ["work", "--control", "bad"],
      ["sessions", "summary", "--type", "bad"],
      ["sessions", "ready", "--prompt-status", "bad"],
      ["sessions", "queues", "--next-action", "bad"],
      ["sessions", "stale", "--seconds", "-1"],
      ["directives"],
      ["operations"],
      ["operations", "ls", "--status", "bad"],
      ["actions"],
      ["actions", "ls", "--kind", "bad"],
      ["approvals"],
      ["approvals", "ls", "--status", "bad"],
      ["notifications"],
      ["notifications", "ls", "--status", "bad"],
      ["policy"],
      ["controls"],
      ["controls", "ls", "--mode", "bad"],
      ["watch"],
      ["watch", "add", "ref", "--goal", "g"],
      ["watch", "add", "ref", "--goal", "g", "--mode", "bad"],
      ["watch", "ls", "--status", "bad"],
      ["operator"],
      ["remote"],
      ["tmux"],
      ["process"],
      ["ssh"],
      ["ssh", "pane-probe"],
      ["session"],
      ["session", "profile", "ref", "--risk", "bad"],
      ["session", "mark", "ref", "--mode", "bad"],
      ["task"],
      ["modes", "bad", "extra"],
      ["unknown"]
    ]

    for args <- invalid_commands do
      assert is_binary(cli_error(args)), "expected CLI error from #{inspect(args)}"
    end
  end

  test "promotion preflight is a dry-run repo gate path" do
    %{project: project} = register_workspace()

    assert cli_json([
             "promote",
             "preflight",
             project,
             "--from",
             "develop",
             "--to",
             "master",
             "--json"
           ])["promotion_preflight"]["project"] == project

    scripts = collect_ssh_scripts()
    repo_doctor_script = Enum.find(scripts, &String.contains?(&1, "jx-repo-doctor"))
    all_scripts = Enum.join(scripts, "\n")

    assert repo_doctor_script
    refute all_scripts =~ " git push "
    refute all_scripts =~ " git merge "
    refute all_scripts =~ " git branch -d "
    refute all_scripts =~ " git branch -D "
    refute all_scripts =~ " git reset --hard "
    refute all_scripts =~ " git worktree remove "
  end

  test "promote run blocked preflight prevents mutation" do
    %{project: project} = register_workspace()

    promotion =
      cli_error_json([
        "promote",
        "run",
        project,
        "--from",
        "develop",
        "--to",
        "master",
        "--json"
      ])["promotion"]

    assert promotion["status"] == "blocked"
    assert promotion["actions"] == []
    assert promotion["errors"] == []

    scripts = collect_ssh_scripts()
    refute Enum.any?(scripts, &String.contains?(&1, "jx-promotion-run"))
  end

  defp register_workspace do
    suffix = System.unique_integer([:positive])
    host = "cli-host-#{suffix}"
    project = "cli-project-#{suffix}"

    Process.put(:fake_ssh_tmux_capture, "recent pane output\n")

    assert cli_output([
             "host",
             "add",
             host,
             "--ssh",
             "developer@example.test",
             "--workspace",
             "/srv/agent"
           ]) =~
             "host #{host} registered"

    assert cli_output(["project", "add", project, "--host", host, "--repo", "/srv/repos/saysure"]) =~
             "project #{project} registered"

    %{host: host, project: project}
  end

  defp cli_output(args) do
    capture_io(fn -> assert :ok = CLI.run(args) end)
  end

  defp cli_json(args) do
    args
    |> cli_output()
    |> Jason.decode!()
  end

  defp cli_error(args) do
    assert {:error, reason} = CLI.run(args)
    to_string(reason)
  end

  defp cli_error_json(args) do
    args
    |> cli_error_output()
    |> Jason.decode!()
  end

  defp cli_error_output(args) do
    capture_io(fn -> assert {:error, _reason} = CLI.run(args) end)
  end

  defp collect_ssh_scripts(scripts \\ []) do
    receive do
      {:ssh_script, script} -> collect_ssh_scripts([script | scripts])
    after
      0 -> Enum.reverse(scripts)
    end
  end

  defp install_fake_tmux! do
    tmp = Path.join(System.tmp_dir!(), "jx-fake-cli-tmux-#{System.unique_integer([:positive])}")
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
