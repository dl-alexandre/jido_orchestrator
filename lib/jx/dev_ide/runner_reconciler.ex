defmodule JX.DevIDE.RunnerReconciler do
  @moduledoc """
  Durable idempotent reconciliation loop for DevIDE runner replay output.

  The loop periodically asks JX for DevIDE runner assignments it already
  enqueued, fetches DevIDE replay through the narrow runner API, and records
  missed evidence into the append-only operational event stream.
  """

  use GenServer

  alias JX.DelegatedExecution
  alias JX.DevIDE.Client

  @default_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def run_once(opts \\ []), do: DelegatedExecution.reconcile_devide_runner_assignments(opts)

  @impl true
  def init(opts) do
    state = %{
      client: Keyword.get_lazy(opts, :client, &Client.new/0),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms)
    }

    # Defer the first reconcile so the rest of the supervision tree (notably
    # JX.Repo) has time to come up before we hit it. Subsequent ticks are
    # scheduled by handle_info/2 at state.interval_ms.
    Process.send_after(self(), :reconcile, state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    _ = run_once(client: state.client)
    Process.send_after(self(), :reconcile, state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
