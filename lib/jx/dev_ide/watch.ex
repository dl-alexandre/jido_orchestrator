defmodule JX.DevIDE.Watch do
  @moduledoc """
  Polling watch loop for the DevIDE portfolio adapter.

  The loop is read-only. Each poll uses `GET /api/workspaces` plus one
  `GET /api/workspaces/:id/status` per workspace.
  """

  alias JX.DevIDE.{Client, Portfolio, State, Status}

  @default_interval_ms 5_000
  @attention_statuses ~w(blocked needs_review)

  @type snapshot :: %{String.t() => map()}
  @type event :: %{
          required(:id) => String.t(),
          required(:name) => String.t() | nil,
          required(:status) => String.t(),
          required(:previous_status) => String.t() | nil,
          required(:attention_flags) => [String.t()]
        }

  @spec default_interval_ms() :: pos_integer()
  def default_interval_ms, do: @default_interval_ms

  @spec run(Client.t(), keyword()) :: :ok | {:error, Client.Error.t()}
  def run(%Client{} = client, opts \\ []) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    max_polls = Keyword.get(opts, :max_polls, :infinity)
    output = Keyword.get(opts, :output, &IO.write/1)
    trap_signals? = Keyword.get(opts, :trap_signals, false)
    persist? = Keyword.get(opts, :persist, false)

    if trap_signals?, do: System.trap_signal(:sigint, true)

    try do
      loop(
        client,
        nil,
        %{interval_ms: interval_ms, max_polls: max_polls, output: output, persist?: persist?},
        0
      )
    after
      if trap_signals?, do: System.trap_signal(:sigint, false)
    end
  end

  @spec poll(Client.t(), snapshot() | nil, keyword()) ::
          {:ok, {snapshot(), [event()]}} | {:error, Client.Error.t()}
  def poll(%Client{} = client, previous \\ nil, opts \\ []) do
    if Keyword.get(opts, :persist, false) do
      poll_persisted(client)
    else
      poll_memory(client, previous)
    end
  end

  defp poll_memory(%Client{} = client, previous) do
    with {:ok, portfolio} <- Portfolio.fetch_snapshot(client) do
      current = snapshot(portfolio)
      {:ok, {current, events(previous, current)}}
    end
  end

  defp poll_persisted(%Client{} = client) do
    with {:ok, report} <- State.ingest(client) do
      {:ok, {snapshot(report.portfolio), Enum.map(report.changes, &watch_event/1)}}
    end
  end

  @spec render_events([event()]) :: String.t()
  def render_events(events) do
    Enum.map_join(events, "", &render_event/1)
  end

  defp loop(_client, _previous, %{max_polls: max_polls}, poll_count)
       when is_integer(max_polls) and poll_count >= max_polls,
       do: :ok

  defp loop(client, previous, ctx, poll_count) do
    receive do
      {:signal, :sigint} ->
        ctx.output.("watch stopped\n")
        :ok
    after
      poll_delay(ctx.interval_ms, poll_count) ->
        case poll(client, previous, persist: ctx.persist?) do
          {:ok, {current, events}} ->
            if events != [], do: ctx.output.(render_events(events))
            loop(client, current, ctx, poll_count + 1)

          {:error, error} ->
            ctx.output.(Client.format_error(error) <> "\n")
            {:error, error}
        end
    end
  end

  defp poll_delay(_interval_ms, 0), do: 0
  defp poll_delay(interval_ms, _poll_count), do: interval_ms

  defp snapshot(%Portfolio{} = portfolio) do
    portfolio
    |> statuses()
    |> Map.new(fn status -> {status.workspace.id, digest(status)} end)
  end

  defp statuses(%Portfolio{} = portfolio) do
    portfolio.healthy ++ portfolio.blocked ++ portfolio.needs_review ++ portfolio.unknown
  end

  defp digest(%Status{} = status) do
    %{
      id: status.workspace.id,
      name: status.workspace.name,
      lifecycle_status: status.workspace.status,
      status: Atom.to_string(status.status),
      db_isolation: status.db_isolation,
      active_run: run_key(status.active_run),
      latest_runs: Enum.map(status.latest_runs, &run_key/1),
      proposal_risks: Enum.map(status.proposal_risks, &proposal_key/1),
      recent_blocks: Enum.map(status.recent_blocks, &block_key/1),
      attention_flags: Enum.sort(status.attention_flags)
    }
  end

  defp events(nil, _current), do: []

  defp events(previous, current) do
    current
    |> Enum.flat_map(fn {_id, current_status} ->
      case Map.fetch(previous, current_status.id) do
        {:ok, previous_status} -> changed_event(previous_status, current_status)
        :error -> new_attention_event(current_status)
      end
    end)
    |> Enum.sort_by(&{&1.id, &1.status})
  end

  defp changed_event(previous_status, current_status) do
    if status_key(previous_status) == status_key(current_status) do
      []
    else
      [event(previous_status.status, current_status)]
    end
  end

  defp new_attention_event(%{status: status} = current_status) when status in @attention_statuses,
    do: [event(nil, current_status)]

  defp new_attention_event(_current_status), do: []

  defp event(previous_status, current_status) do
    %{
      id: current_status.id,
      name: current_status.name,
      previous_status: previous_status,
      status: current_status.status,
      attention_flags: current_status.attention_flags
    }
  end

  defp watch_event(change) do
    %{
      id: change.id,
      name: change.name,
      previous_status: change.previous_status,
      status: change.status,
      attention_flags: change.attention_flags
    }
  end

  defp status_key(status) do
    Map.take(status, [
      :status,
      :db_isolation,
      :active_run,
      :latest_runs,
      :proposal_risks,
      :recent_blocks,
      :attention_flags
    ])
  end

  defp render_event(event) do
    marker = if event.status in @attention_statuses, do: "!", else: "-"
    transition = transition(event.previous_status, event.status)

    flags =
      if event.attention_flags == [], do: "none", else: Enum.join(event.attention_flags, ",")

    next = "next=\"jx approvals ls --source devide --workspace #{event.id}\""

    "#{marker} #{transition} #{event.id} #{event.name || "-"} flags=#{flags} #{next}\n"
  end

  defp transition(nil, status), do: status
  defp transition(status, status), do: status
  defp transition(previous_status, status), do: "#{previous_status}->#{status}"

  defp run_key(nil), do: nil

  defp run_key(run) when is_map(run) do
    Map.take(run, [:id, :command_id, :status, :exit_code, :duration_ms, :started_at, :finished_at])
  end

  defp proposal_key(proposal) when is_map(proposal) do
    Map.take(proposal, [:path, :risk, :files_count, :overlapping_files])
  end

  defp block_key(block) when is_map(block) do
    Map.take(block, [:action, :target_type, :target_ref, :reason, :inserted_at])
  end
end
