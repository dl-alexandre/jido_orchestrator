defmodule JX.Jido.SignalDispatch.Orchestrator do
  @moduledoc """
  Jido signal dispatcher that delivers operational events to the orchestrator agent.

  `Jido.Signal.Dispatch` adapters are configured without runtime PIDs, while the
  supervised `Jido.AgentServer` PID is discovered through the Jido registry. This
  keeps monitor event dispatch durable across orchestrator restarts.
  """

  @behaviour Jido.Signal.Dispatch.Adapter

  alias JX.OrchestratorRuntime

  @valid_delivery_modes [:async, :sync]

  @impl true
  def validate_opts(opts) when is_list(opts) do
    delivery_mode = Keyword.get(opts, :delivery_mode, :async)
    timeout = Keyword.get(opts, :timeout, 5_000)

    cond do
      delivery_mode not in @valid_delivery_modes ->
        {:error, :invalid_delivery_mode}

      not (is_integer(timeout) and timeout > 0) ->
        {:error, :invalid_timeout}

      true ->
        {:ok,
         opts
         |> Keyword.put(:delivery_mode, delivery_mode)
         |> Keyword.put(:timeout, timeout)}
    end
  end

  def validate_opts(_opts), do: {:error, :invalid_options}

  @impl true
  def deliver(%Jido.Signal{} = signal, opts) do
    with {:ok, pid} <- orchestrator_pid() do
      case Keyword.fetch!(opts, :delivery_mode) do
        :async -> Jido.AgentServer.cast(pid, signal)
        :sync -> call(pid, signal, Keyword.fetch!(opts, :timeout))
      end
    end
  end

  defp orchestrator_pid do
    case OrchestratorRuntime.whereis() do
      nil -> {:error, :orchestrator_agent_not_started}
      pid -> {:ok, pid}
    end
  end

  defp call(pid, signal, timeout) do
    case Jido.AgentServer.call(pid, signal, timeout) do
      {:ok, _agent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end
end
