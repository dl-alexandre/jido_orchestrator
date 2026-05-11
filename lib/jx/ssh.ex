defmodule JX.SSH do
  @moduledoc """
  Behaviour for remote command execution.
  """

  alias JX.Hosts.Host

  @callback run(Host.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback attach(Host.t(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback stream_log(Host.t(), String.t(), keyword()) :: :ok | {:error, term()}

  def adapter(%Host{} = host) do
    if Host.local?(host) do
      Application.get_env(:jx, :local_adapter, JX.SSH.Local)
    else
      adapter()
    end
  end

  def adapter do
    Application.get_env(:jx, :ssh_adapter, JX.SSH.System)
  end
end
