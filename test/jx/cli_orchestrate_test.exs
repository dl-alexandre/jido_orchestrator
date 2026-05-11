defmodule JX.CLIOrchestrateTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JX.CLI
  alias JX.CallHandoffs.CallHandoff
  alias JX.CiWatches.CiWatch
  alias JX.Delegations.Delegation
  alias JX.Directives.Directive
  alias JX.Hosts.Host
  alias JX.MonitorEvents.Cursor
  alias JX.MonitorEvents.Event
  alias JX.Notifications.Notification
  alias JX.OperationExecutions.OperationExecution
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.OrchestratorHeartbeats.Heartbeat
  alias JX.Projects.Project
  alias JX.RemoteSessions.RemoteSessionObservation
  alias JX.Repo
  alias JX.SessionControls.SessionControl
  alias JX.SessionObservations.SessionObservation
  alias JX.SessionProfiles.OperatorProfile
  alias JX.SessionProfiles.SessionProfile
  alias JX.SessionWatches.SessionWatch
  alias JX.Tasks.Task, as: JidoTask
  alias JX.Workspace

  setup do
    Repo.delete_all(SessionObservation)
    Repo.delete_all(Cursor)
    Repo.delete_all(Event)
    Repo.delete_all(Notification)
    Repo.delete_all(CallHandoff)
    Repo.delete_all(Delegation)
    Repo.delete_all(Heartbeat)
    Repo.delete_all(OrchestrationAction)
    Repo.delete_all(OperationExecution)
    Repo.delete_all(CiWatch)
    Repo.delete_all(RemoteSessionObservation)
    Repo.delete_all(SessionProfile)
    Repo.delete_all(OperatorProfile)
    Repo.delete_all(SessionWatch)
    Repo.delete_all(SessionControl)
    Repo.delete_all(Directive)
    Repo.delete_all(JidoTask)
    Repo.delete_all(Project)
    Repo.delete_all(Host)

    {:ok, _host} =
      Workspace.add_host(%{
        name: "build-1",
        ssh_target: "developer@example.test",
        workspace_path: "/srv/agent"
      })

    {:ok, _project} =
      Workspace.add_project(%{
        name: "saysure",
        host_name: "build-1",
        repo_path: "/srv/repos/saysure"
      })

    :ok
  end

  test "non-json orchestrate run prints surface decisions" do
    assert {:ok, _handoff} =
             Workspace.create_call_handoff(
               %{
                 ref: "s-call",
                 project: "saysure",
                 title: "Operator call follow-up",
                 summary: "Review the call handoff."
               },
               brief: false
             )

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "orchestrate",
                   "run",
                   "--iterations",
                   "1",
                   "--host",
                   "build-1",
                   "--no-observe",
                   "--decision-limit",
                   "100",
                   "--auto-plan"
                 ])
      end)

    assert output =~ "orchestrate iteration 1"
    assert output =~ "review-call-handoff"
    assert output =~ "Operator call follow-up"
    assert output =~ "execution: dry-run"
  end

  test "infinite orchestrate run records an error heartbeat and retries after exceptions" do
    parent = self()

    task =
      Task.async(fn ->
        Process.put(:jx_cli_orchestrate_fun, fn _opts ->
          send(parent, :orchestrate_called)
          raise "injected loop failure"
        end)

        capture_io(:stderr, fn ->
          CLI.run([
            "orchestrate",
            "run",
            "--consumer",
            "loop-error-test",
            "--interval-ms",
            "1",
            "--no-observe"
          ])
        end)
      end)

    assert_receive :orchestrate_called, 1_000
    assert_receive :orchestrate_called, 1_000

    Task.shutdown(task, :brutal_kill)

    assert %Heartbeat{} = heartbeat = Repo.get_by!(Heartbeat, daemon_key: "loop-error-test")
    assert heartbeat.status == "error"
    assert heartbeat.mode == "dry-run"
    assert heartbeat.last_error =~ "injected loop failure"
  end
end
