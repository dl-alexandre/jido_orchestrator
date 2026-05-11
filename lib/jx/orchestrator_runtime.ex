defmodule JX.OrchestratorRuntime do
  @moduledoc """
  Supervised Jido runtime process for compact orchestration state.
  """

  alias JX.OrchestratorAgent

  def child_spec(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:jido, JX.Jido)
      |> Keyword.put_new(:agent, OrchestratorAgent)
      |> Keyword.put_new(:id, OrchestratorAgent.id())

    Supervisor.child_spec({Jido.AgentServer, opts}, id: __MODULE__)
  end

  def whereis do
    Jido.whereis(JX.Jido, OrchestratorAgent.id())
  end

  def state do
    with {:ok, pid} <- pid() do
      Jido.AgentServer.state(pid)
    end
  end

  def status do
    with {:ok, pid} <- pid() do
      Jido.AgentServer.status(pid)
    end
  end

  def refresh(opts \\ []) do
    with {:ok, pid} <- pid() do
      {timeout, opts} = Keyword.pop(opts, :timeout, 30_000)
      Jido.AgentServer.call(pid, OrchestratorAgent.refresh_signal(opts), timeout)
    end
  end

  defp pid do
    case whereis() do
      nil -> {:error, :orchestrator_agent_not_started}
      pid -> {:ok, pid}
    end
  end
end
