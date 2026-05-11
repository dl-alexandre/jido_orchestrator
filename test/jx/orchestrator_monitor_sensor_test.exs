defmodule JX.OrchestratorMonitorSensorTest do
  use ExUnit.Case, async: false

  alias JX.Directives.Directive
  alias JX.Hosts.Host
  alias JX.Jido.Sensors.MonitorScan
  alias JX.MonitorEvents.Cursor
  alias JX.MonitorEvents.Event
  alias JX.Notifications.Notification
  alias JX.OrchestratorAgent
  alias JX.OrchestratorMonitorSensor
  alias JX.OrchestratorRuntime
  alias JX.Projects.Project
  alias JX.Repo
  alias JX.SessionObservations.SessionObservation
  alias JX.SessionProfiles.OperatorProfile
  alias JX.SessionProfiles.SessionProfile
  alias JX.Tasks.Task
  alias JX.WakeTriggers.WakeTrigger
  alias JX.Workspace

  setup do
    Repo.delete_all(WakeTrigger)
    Repo.delete_all(SessionObservation)
    Repo.delete_all(Cursor)
    Repo.delete_all(Event)
    Repo.delete_all(Notification)
    Repo.delete_all(SessionProfile)
    Repo.delete_all(OperatorProfile)
    Repo.delete_all(Directive)
    Repo.delete_all(Task)
    Repo.delete_all(Project)
    Repo.delete_all(Host)

    previous_dispatch = Application.get_env(:jx, :monitor_event_dispatch)

    on_exit(fn ->
      Application.put_env(:jx, :monitor_event_dispatch, previous_dispatch)
    end)

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

  test "child specs are opt-in for application supervision" do
    assert OrchestratorMonitorSensor.child_specs(enabled: false) == []

    assert [
             %{
               id: JX.OrchestratorMonitorSensor,
               start: {Jido.Sensor.Runtime, :start_link, [opts]}
             }
           ] =
             OrchestratorMonitorSensor.child_specs(
               enabled: true,
               interval_ms: 60_000,
               run_on_start: false,
               opts: [host_name: "build-1", type: "agent"]
             )

    assert opts[:sensor] == MonitorScan
    assert opts[:config][:interval_ms] == 60_000
    assert opts[:context][:jido_instance] == JX.Jido
  end

  test "monitor scan sensor emits completed scan signals through Jido Sensor.Runtime" do
    Application.put_env(:jx, :monitor_event_dispatch, {:noop, []})

    {:ok, pid} =
      Jido.Sensor.Runtime.start_link(
        sensor: MonitorScan,
        config: [
          interval_ms: 60_000,
          run_on_start: false,
          opts: [host_name: "build-1", type: "agent", observe: false]
        ],
        context: %{agent_ref: self()}
      )

    on_exit(fn -> stop_sensor(pid) end)

    Jido.Sensor.Runtime.event(pid, :scan)

    assert_receive {:signal, %Jido.Signal{} = signal}, 5_000

    assert signal.type == MonitorScan.completed_signal_type()
    assert signal.source == "/jx/sensors/monitor_scan"
    assert signal.data.status == "completed"
    assert signal.data.sessions_total == 1
    assert signal.data.events_saved >= 1
  end

  test "monitor scan sensor can update the supervised orchestrator agent" do
    Application.put_env(:jx, :monitor_event_dispatch, {:noop, []})

    agent_pid = OrchestratorRuntime.whereis()
    assert is_pid(agent_pid)
    assert {:ok, before_state} = OrchestratorRuntime.state()
    previous_scan_total = before_state.agent.state.scan_total
    agent_ref = Jido.AgentServer.via_tuple(OrchestratorAgent.id(), JX.Jido.registry_name())

    {:ok, pid} =
      Jido.Sensor.Runtime.start_link(
        sensor: MonitorScan,
        config: [
          interval_ms: 60_000,
          run_on_start: false,
          opts: [host_name: "build-1", type: "agent", observe: false]
        ],
        context: %{
          agent_ref: agent_ref,
          jido_instance: JX.Jido
        }
      )

    on_exit(fn -> stop_sensor(pid) end)

    Jido.Sensor.Runtime.event(pid, :scan)

    assert_eventually(fn ->
      assert {:ok, state} = OrchestratorRuntime.state()
      assert state.agent.state.scan_total == previous_scan_total + 1
      assert state.agent.state.last_scan_status == "completed"
      assert state.agent.state.last_scan_sessions_total == 1
    end)
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
  end

  defp assert_eventually(fun, 0), do: fun.()

  defp stop_sensor(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
