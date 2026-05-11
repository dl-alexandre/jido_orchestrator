defmodule JX.OrchestratorMonitorSensor do
  @moduledoc """
  Optional supervised Jido sensor runtime for monitor scans.

  The tmux daemon remains available for detached CLI operation. This supervisor
  child gives OTP deployments a Jido-native scan loop without changing the
  durable Workspace implementation.
  """

  alias JX.OrchestratorAgent
  alias JX.Jido.Sensors.MonitorScan

  @config_key :monitor_sensor

  def child_specs(opts \\ app_config()) do
    opts = normalize_opts(opts)

    if Keyword.get(opts, :enabled, false) do
      [child_spec(opts)]
    else
      []
    end
  end

  def child_spec(opts \\ app_config()) do
    opts = normalize_opts(opts)

    runtime_opts = [
      sensor: MonitorScan,
      id: Keyword.get(opts, :id, "jx_monitor_scan"),
      config: sensor_config(opts),
      context: sensor_context(opts)
    ]

    Supervisor.child_spec({Jido.Sensor.Runtime, runtime_opts}, id: __MODULE__)
  end

  defp app_config do
    Application.get_env(:jx, @config_key, [])
  end

  defp sensor_config(opts) do
    [
      interval_ms: Keyword.get(opts, :interval_ms, 30_000),
      run_on_start: Keyword.get(opts, :run_on_start, false),
      opts: Keyword.get(opts, :opts, [])
    ]
  end

  defp sensor_context(opts) do
    Keyword.get(opts, :context) ||
      %{
        agent_ref: Keyword.get(opts, :agent_ref, orchestrator_agent_ref()),
        jido_instance: JX.Jido
      }
  end

  defp orchestrator_agent_ref do
    Jido.AgentServer.via_tuple(OrchestratorAgent.id(), JX.Jido.registry_name())
  end

  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(_opts), do: []
end
