defmodule JX.CLI.DevIDE do
  @moduledoc """
  CLI entrypoint for `jx devide ...` read-only portfolio commands.
  """

  alias JX.DevIDE.{Client, Portfolio, Status, Watch, Workspace}

  @usage """
  usage:
    jx devide workspaces
    jx devide status <workspace_id>
    jx devide portfolio
    jx devide risks
    jx devide watch [--interval-ms N] [--state]
  """

  @spec main([String.t()]) :: no_return()
  def main(args) do
    {code, output} = run(args, writer: &IO.write/1, trap_signals: true)

    if code == 0 do
      IO.write(output)
    else
      IO.write(:stderr, output)
    end

    System.halt(code)
  end

  @spec run([String.t()], keyword()) :: {non_neg_integer(), String.t()}
  def run(args, opts \\ []) do
    client = Keyword.get_lazy(opts, :client, &Client.new/0)

    case dispatch(args, client, opts) do
      {:ok, output} -> {0, output}
      {:error, %Client.Error{} = error} -> {1, Client.format_error(error) <> "\n"}
      {:error, message} -> {1, message <> "\n"}
    end
  end

  defp dispatch(["devide", "workspaces"], client, _opts) do
    with {:ok, payloads} <- Client.workspaces(client) do
      payloads
      |> Enum.map(&Workspace.from_payload/1)
      |> render_workspaces()
      |> ok()
    end
  end

  defp dispatch(["devide", "status", workspace_id], client, _opts) do
    with {:ok, status} <- Status.fetch(client, workspace_id) do
      status
      |> render_status()
      |> ok()
    end
  end

  defp dispatch(["devide", "portfolio"], client, _opts) do
    with {:ok, portfolio} <- Portfolio.fetch(client) do
      portfolio
      |> render_portfolio()
      |> ok()
    end
  end

  defp dispatch(["devide", "risks"], client, _opts) do
    with {:ok, portfolio} <- Portfolio.fetch(client) do
      portfolio
      |> render_risks()
      |> ok()
    end
  end

  defp dispatch(["devide", "watch" | args], client, opts) do
    case watch_opts(args, opts) do
      {:ok, watch_opts} ->
        case Watch.run(client, watch_opts) do
          :ok -> {:ok, ""}
          {:error, error} -> {:error, error}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp dispatch(["devide" | _], _client, _opts), do: {:error, String.trim_trailing(@usage)}
  defp dispatch(_args, _client, _opts), do: {:error, String.trim_trailing(@usage)}

  @spec requires_state?([String.t()]) :: boolean()
  def requires_state?(["devide", "watch" | args]) do
    {parsed, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          interval_ms: :integer,
          interval: :integer,
          max_polls: :integer,
          once: :boolean,
          state: :boolean,
          persist: :boolean
        ]
      )

    parsed[:state] || parsed[:persist] || false
  end

  def requires_state?(_args), do: false

  defp ok(output), do: {:ok, output}

  defp watch_opts(args, run_opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          interval_ms: :integer,
          interval: :integer,
          max_polls: :integer,
          once: :boolean,
          state: :boolean,
          persist: :boolean
        ]
      )

    cond do
      invalid != [] ->
        {:error, "invalid watch option"}

      rest != [] ->
        {:error, String.trim_trailing(@usage)}

      true ->
        with {:ok, interval_ms} <- watch_interval_ms(parsed, run_opts),
             {:ok, max_polls} <- watch_max_polls(parsed, run_opts) do
          {:ok,
           [
             interval_ms: interval_ms,
             max_polls: max_polls,
             output: Keyword.get(run_opts, :writer, &IO.write/1),
             trap_signals: Keyword.get(run_opts, :trap_signals, false),
             persist: watch_persist?(parsed, run_opts)
           ]}
        end
    end
  end

  defp watch_persist?(parsed, run_opts) do
    parsed[:state] || parsed[:persist] || Keyword.get(run_opts, :persist, false)
  end

  defp watch_interval_ms(parsed, run_opts) do
    interval_ms =
      cond do
        is_integer(parsed[:interval_ms]) -> parsed[:interval_ms]
        is_integer(parsed[:interval]) -> parsed[:interval] * 1_000
        is_integer(run_opts[:interval_ms]) -> run_opts[:interval_ms]
        true -> Watch.default_interval_ms()
      end

    if interval_ms > 0, do: {:ok, interval_ms}, else: {:error, "watch interval must be positive"}
  end

  defp watch_max_polls(parsed, run_opts) do
    max_polls =
      cond do
        parsed[:once] -> 1
        is_integer(parsed[:max_polls]) -> parsed[:max_polls]
        is_integer(run_opts[:max_polls]) -> run_opts[:max_polls]
        true -> :infinity
      end

    if max_polls == :infinity or max_polls > 0,
      do: {:ok, max_polls},
      else: {:error, "watch max polls must be positive"}
  end

  defp render_workspaces([]), do: "workspaces\n  none\n"

  defp render_workspaces(workspaces) do
    lines =
      workspaces
      |> Enum.sort_by(&{String.downcase(&1.name || ""), &1.id})
      |> Enum.map(fn ws ->
        "  #{ws.id}  #{ws.name || "-"}  #{ws.status || "-"}"
      end)

    Enum.join(["workspaces" | lines], "\n") <> "\n"
  end

  defp render_status(%Status{} = status) do
    sections = [
      render_workspace(status),
      render_runs(status.latest_runs),
      render_proposal_risks(status.proposal_risks),
      render_recent_blocks(status.recent_blocks),
      render_operator_flow(status)
    ]

    Enum.join(sections, "\n") <> "\n"
  end

  defp render_workspace(%Status{} = status) do
    active_run =
      case status.active_run do
        nil -> "none"
        run -> "#{run.command_id || "-"} #{run.status || "-"}"
      end

    flags =
      case status.attention_flags do
        [] -> "none"
        list -> Enum.join(list, ", ")
      end

    """
    workspace
      id: #{status.workspace.id}
      name: #{status.workspace.name || "-"}
      status: #{status.status}
      lifecycle_status: #{status.workspace.status || "-"}
      mode: #{status.mode || "-"}
      db_isolation: #{status.db_isolation || "unknown"}
      active_run: #{active_run}
      attention_flags: #{flags}
    """
    |> String.trim_trailing()
  end

  defp render_runs([]), do: "latest_runs\n  none"

  defp render_runs(runs) do
    lines =
      runs
      |> Enum.take(10)
      |> Enum.map(fn run ->
        details =
          [
            run.exit_code && "exit=#{run.exit_code}",
            run.duration_ms && "duration_ms=#{run.duration_ms}",
            run.finished_at && "finished_at=#{run.finished_at}"
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")

        suffix = if details == "", do: "", else: " #{details}"
        "  #{run.command_id || "-"} #{run.status || "-"}#{suffix}"
      end)

    Enum.join(["latest_runs" | lines], "\n")
  end

  defp render_proposal_risks([]), do: "proposal_risks\n  none"

  defp render_proposal_risks(proposal_risks) do
    lines =
      Enum.map(proposal_risks, fn proposal ->
        overlaps =
          case proposal.overlapping_files do
            [] -> ""
            files -> " overlaps=#{Enum.join(files, ",")}"
          end

        "  #{proposal.path || "-"} #{proposal.risk || "-"} files=#{proposal.files_count || 0}#{overlaps}"
      end)

    Enum.join(["proposal_risks" | lines], "\n")
  end

  defp render_recent_blocks([]), do: "recent_blocks\n  none"

  defp render_recent_blocks(recent_blocks) do
    lines =
      Enum.map(recent_blocks, fn block ->
        target =
          [block.target_type, block.target_ref]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(":")

        target_suffix = if target == "", do: "", else: " target=#{target}"
        reason_suffix = if block.reason, do: " reason=#{block.reason}", else: ""
        time_suffix = if block.inserted_at, do: " at=#{block.inserted_at}", else: ""
        "  #{block.action || "policy.blocked"}#{target_suffix}#{reason_suffix}#{time_suffix}"
      end)

    Enum.join(["recent_blocks" | lines], "\n")
  end

  defp render_operator_flow(%Status{} = status) do
    workspace_id = status.workspace.id

    [
      "operator_flow",
      "  approvals: jx approvals ls --source devide --workspace #{workspace_id}",
      "  approval_detail: jx approvals show <approval-id>",
      "  propose_action: jx actions propose <approval-id> [--kind acknowledge_approval]",
      "  audit_action: jx actions history <approval-id>"
    ]
    |> Enum.join("\n")
  end

  defp render_portfolio(%Portfolio{} = portfolio) do
    [
      "portfolio",
      "  total: #{portfolio.total}",
      "  healthy: #{length(portfolio.healthy)}",
      "  blocked: #{length(portfolio.blocked)}",
      "  needs_review: #{length(portfolio.needs_review)}",
      "  unknown: #{length(portfolio.unknown)}",
      render_group("healthy", portfolio.healthy),
      render_group("blocked", portfolio.blocked),
      render_group("needs_review", portfolio.needs_review),
      render_group("unknown", portfolio.unknown),
      render_portfolio_next(portfolio)
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp render_group(_name, []), do: nil

  defp render_group(name, statuses) do
    lines =
      Enum.map(statuses, fn status ->
        flags =
          case status.attention_flags do
            [] -> "none"
            list -> Enum.join(list, ",")
          end

        "  #{status.workspace.id} #{status.workspace.name || "-"} flags=#{flags}"
      end)

    Enum.join([name | lines], "\n")
  end

  defp render_portfolio_next(%Portfolio{} = portfolio) do
    if Portfolio.risks(portfolio) == [] do
      nil
    else
      [
        "operator_flow",
        "  risks: jx devide risks",
        "  persist_snapshots: jx devide watch --state --interval-ms 5000",
        "  approvals: jx approvals ls --source devide"
      ]
      |> Enum.join("\n")
    end
  end

  defp render_risks(%Portfolio{} = portfolio) do
    case Portfolio.risks(portfolio) do
      [] ->
        "risks\n  none\n"

      statuses ->
        lines =
          Enum.map(statuses, fn status ->
            "  #{status.workspace.id} #{status.status} #{Enum.join(status.attention_flags, ",")}"
          end)

        next = [
          "operator_flow",
          "  persist_snapshots: jx devide watch --state --interval-ms 5000",
          "  approvals: jx approvals ls --source devide",
          "  approval_detail: jx approvals show <approval-id>"
        ]

        Enum.join(["risks" | lines] ++ next, "\n") <> "\n"
    end
  end
end
