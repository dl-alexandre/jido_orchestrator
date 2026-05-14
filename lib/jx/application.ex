defmodule JX.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        JX.Repo,
        JX.Jido,
        JX.OrchestratorRuntime,
        JX.HostCapacity.CapacityPoller
      ] ++ JX.OrchestratorMonitorSensor.child_specs()

    opts = [strategy: :one_for_one, name: JX.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    maybe_burrito_dispatch()

    {:ok, pid}
  end

  defp maybe_burrito_dispatch do
    if burrito_running?() do
      Task.start(fn ->
        args = apply(Burrito.Util.Args, :get_arguments, [])
        JX.CLI.main(args)
        System.stop(0)
      end)
    end
  end

  defp burrito_running? do
    Code.ensure_loaded?(Burrito.Util.Args) and
      apply(Burrito.Util.Args, :running_standalone?, [])
  end
end
