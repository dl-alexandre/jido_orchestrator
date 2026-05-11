defmodule JX.ProjectBriefTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JX.CLI
  alias JX.CallHandoffs.CallHandoff
  alias JX.CiWatches.CiWatch
  alias JX.Delegations.Delegation
  alias JX.Directives.Directive
  alias JX.Hosts.Host
  alias JX.MonitorEvents.Event
  alias JX.Notifications.Notification
  alias JX.Projects.Project
  alias JX.Repo
  alias JX.Tasks.Task
  alias JX.WakeTriggers.WakeTrigger
  alias JX.Workspace

  setup do
    Repo.delete_all(WakeTrigger)
    Repo.delete_all(Notification)
    Repo.delete_all(Event)
    Repo.delete_all(CallHandoff)
    Repo.delete_all(Delegation)
    Repo.delete_all(CiWatch)
    Repo.delete_all(Directive)
    Repo.delete_all(Task)
    Repo.delete_all(Project)
    Repo.delete_all(Host)

    {:ok, _host} =
      Workspace.add_host(%{
        name: "local",
        transport: "local",
        workspace_path: "/tmp/jx"
      })

    {:ok, _project} =
      Workspace.add_project(%{
        name: "saysure",
        host_name: "local",
        repo_path: "/tmp/saysure"
      })

    on_exit(fn ->
      Repo.delete_all(WakeTrigger)
      Repo.delete_all(Notification)
      Repo.delete_all(Event)
      Repo.delete_all(CallHandoff)
      Repo.delete_all(Delegation)
      Repo.delete_all(CiWatch)
      Repo.delete_all(Directive)
      Repo.delete_all(Task)
      Repo.delete_all(Project)
      Repo.delete_all(Host)
    end)

    :ok
  end

  test "workspace project brief aggregates project orchestration state" do
    seed_project_state()

    assert {:ok, brief} = Workspace.project_brief("saysure", observe: false)

    assert brief.project.name == "saysure"
    assert brief.project.registered == true
    assert brief.counts.notifications == 1
    assert brief.counts.ci_watches == 1
    assert brief.counts.handoffs == 1
    assert brief.counts.delegations == 1
    assert brief.counts.wake_triggers == 1
    assert brief.next.mode == "tui"
    assert brief.mode.id == "tui"
    assert "jx project brief saysure --observe --json" in brief.commands
  end

  test "CLI project brief returns JSON gateway packet" do
    seed_project_state()

    output =
      capture_io(fn ->
        assert :ok = CLI.run(["project", "brief", "saysure", "--no-observe", "--json"])
      end)

    assert %{
             "project_brief" => %{
               "project" => %{"name" => "saysure", "registered" => true},
               "counts" => %{
                 "notifications" => 1,
                 "ci_watches" => 1,
                 "handoffs" => 1,
                 "delegations" => 1,
                 "wake_triggers" => 1
               },
               "mode" => %{"id" => "tui"}
             }
           } = Jason.decode!(output)
  end

  defp seed_project_state do
    {:ok, _wake} =
      Workspace.wake(%{
        message: "review project incident",
        project: "saysure",
        severity: "warning"
      })

    {:ok, _watch} =
      Workspace.add_ci_watch(%{
        repo: "owner/repo",
        pr_number: 42,
        project: "saysure",
        goal: "wait for CI"
      })

    {:ok, _handoff} =
      Workspace.create_call_handoff(
        %{
          title: "Project follow-up",
          summary: "Review project handoff",
          project: "saysure",
          surface: "call"
        },
        brief: false
      )

    {:ok, _delegation} =
      Workspace.create_delegation(%{
        project: "saysure",
        title: "Project cleanup",
        brief: "Tighten project brief tests",
        write_paths: ["test/jx/project_brief_test.exs"]
      })

    {:ok, _trigger} =
      Workspace.add_wake_trigger(%{
        message: "scheduled project review",
        project: "saysure",
        severity: "notice",
        schedule: "once",
        next_run_at: DateTime.add(DateTime.utc_now(), 300, :second)
      })
  end
end
