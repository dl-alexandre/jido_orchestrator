defmodule JX.DevIDE.Status do
  @moduledoc """
  Builds a JX workspace/session dossier from DevIDE read-only API payloads.
  """

  alias JX.DevIDE.{Client, Workspace}

  @proposal_review_risks ~w(overlap conflict invalid)
  @blocked_isolations ~w(shared_stage unsafe)
  @failed_run_statuses ~w(failed timed_out)

  @type portfolio_status :: :healthy | :blocked | :needs_review | :unknown

  @type run_summary :: %{
          optional(:id) => String.t() | nil,
          required(:command_id) => String.t() | nil,
          required(:status) => String.t() | nil,
          optional(:exit_code) => String.t() | nil,
          optional(:duration_ms) => integer() | nil,
          optional(:started_at) => String.t() | nil,
          optional(:finished_at) => String.t() | nil
        }

  @type proposal_risk :: %{
          required(:path) => String.t() | nil,
          required(:risk) => String.t() | nil,
          optional(:files_count) => non_neg_integer() | nil,
          optional(:overlapping_files) => [String.t()]
        }

  @type recent_block :: %{
          required(:action) => String.t() | nil,
          optional(:target_type) => String.t() | nil,
          optional(:target_ref) => String.t() | nil,
          optional(:reason) => String.t() | nil,
          optional(:inserted_at) => String.t() | nil
        }

  @type t :: %__MODULE__{
          workspace: Workspace.t(),
          status: portfolio_status(),
          mode: String.t() | nil,
          db_isolation: String.t() | nil,
          active_run: run_summary() | nil,
          latest_runs: [run_summary()],
          proposal_risks: [proposal_risk()],
          recent_blocks: [recent_block()],
          attention_flags: [String.t()]
        }

  @enforce_keys [:workspace, :status]
  defstruct [
    :workspace,
    :status,
    :mode,
    :db_isolation,
    :active_run,
    latest_runs: [],
    proposal_risks: [],
    recent_blocks: [],
    attention_flags: []
  ]

  @spec fetch(Client.t(), String.t()) :: {:ok, t()} | {:error, Client.Error.t()}
  def fetch(%Client{} = client, workspace_id) do
    with {:ok, status_payload} <- Client.status(client, workspace_id),
         {:ok, runs} <- Client.runs(client, workspace_id),
         {:ok, proposals} <- Client.proposals(client, workspace_id),
         {:ok, audit} <- Client.audit(client, workspace_id) do
      {:ok, from_payload(status_payload, runs, proposals, audit)}
    end
  end

  @doc """
  Fetches the workspace status payload only.

  DevIDE's `/status` response already includes recent runs, proposals, and audit
  summaries. The watch command uses this path to keep polling cheap and limited
  to `/api/workspaces` plus per-workspace `/status` endpoints.
  """
  @spec fetch_snapshot(Client.t(), String.t()) :: {:ok, t()} | {:error, Client.Error.t()}
  def fetch_snapshot(%Client{} = client, workspace_id) do
    with {:ok, status_payload} <- Client.status(client, workspace_id) do
      {:ok, from_payload(status_payload)}
    end
  end

  @spec from_payload(map(), [map()] | nil, [map()] | nil, [map()] | nil) :: t()
  def from_payload(status_payload, runs \\ nil, proposals \\ nil, audit \\ nil)
      when is_map(status_payload) do
    workspace = Workspace.from_payload(field(status_payload, "workspace") || %{})
    mode = status_payload |> field("mode") |> field("value") |> stringify()
    db_isolation = status_payload |> field("db_isolation") |> field("isolation") |> stringify()
    active_run = normalize_active_run(field(status_payload, "active_run"))

    latest_runs =
      runs
      |> fallback_list(field(status_payload, "recent_runs"))
      |> Enum.map(&normalize_run/1)

    proposal_risks =
      proposals
      |> fallback_list(field(status_payload, "recent_proposals"))
      |> Enum.map(&normalize_proposal/1)
      |> Enum.filter(&proposal_risk?/1)

    recent_blocks =
      audit
      |> fallback_list(field(status_payload, "recent_audit"))
      |> Enum.map(&normalize_audit/1)
      |> Enum.filter(&policy_block?/1)

    attention_flags =
      attention_flags(%{
        db_isolation: db_isolation,
        active_run: active_run,
        latest_runs: latest_runs,
        proposal_risks: proposal_risks,
        recent_blocks: recent_blocks
      })

    %__MODULE__{
      workspace: workspace,
      status: portfolio_status(attention_flags, latest_runs, db_isolation),
      mode: mode,
      db_isolation: db_isolation || "unknown",
      active_run: active_run,
      latest_runs: latest_runs,
      proposal_risks: proposal_risks,
      recent_blocks: recent_blocks,
      attention_flags: attention_flags
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = status) do
    %{
      workspace: %{
        id: status.workspace.id,
        name: status.workspace.name,
        status: Atom.to_string(status.status),
        lifecycle_status: status.workspace.status,
        mode: status.mode,
        db_isolation: status.db_isolation,
        active_run: status.active_run,
        latest_runs: status.latest_runs,
        proposal_risks: status.proposal_risks,
        recent_blocks: status.recent_blocks,
        attention_flags: status.attention_flags
      }
    }
  end

  defp attention_flags(ctx) do
    []
    |> add_db_isolation_flags(ctx.db_isolation)
    |> add_active_run_flags(ctx.active_run)
    |> add_proposal_flags(ctx.proposal_risks)
    |> add_recent_block_flags(ctx.recent_blocks)
    |> add_latest_run_flags(ctx.latest_runs, "compile")
    |> add_latest_run_flags(ctx.latest_runs, "test")
    |> Enum.reverse()
  end

  defp add_db_isolation_flags(flags, isolation) when isolation in @blocked_isolations,
    do: ["db_isolation:#{isolation}" | flags]

  defp add_db_isolation_flags(flags, _), do: flags

  defp add_active_run_flags(flags, %{status: status}) when status in @failed_run_statuses,
    do: ["active_run:#{status}" | flags]

  defp add_active_run_flags(flags, _), do: flags

  defp add_proposal_flags(flags, proposal_risks) do
    proposal_risks
    |> Enum.map(& &1.risk)
    |> Enum.uniq()
    |> Enum.reduce(flags, fn risk, acc -> ["proposal:#{risk}" | acc] end)
  end

  defp add_recent_block_flags(flags, []), do: flags
  defp add_recent_block_flags(flags, _recent_blocks), do: ["policy_blocked:recent" | flags]

  defp add_latest_run_flags(flags, latest_runs, command_id) do
    case latest_command_run(latest_runs, command_id) do
      %{status: "succeeded"} -> flags
      %{status: status} when is_binary(status) -> ["latest_#{command_id}:#{status}" | flags]
      nil -> ["latest_#{command_id}:missing" | flags]
    end
  end

  defp portfolio_status(flags, latest_runs, db_isolation) do
    cond do
      blocked_flags?(flags) -> :blocked
      Enum.any?(flags, &String.starts_with?(&1, "proposal:")) -> :needs_review
      healthy?(flags, latest_runs, db_isolation) -> :healthy
      true -> :unknown
    end
  end

  defp blocked_flags?(flags) do
    Enum.any?(flags, fn flag ->
      String.starts_with?(flag, "db_isolation:") or
        String.starts_with?(flag, "active_run:") or
        flag == "policy_blocked:recent"
    end)
  end

  defp healthy?(flags, latest_runs, db_isolation) do
    no_attention? = flags == []
    compile_ok? = match?(%{status: "succeeded"}, latest_command_run(latest_runs, "compile"))
    test_ok? = match?(%{status: "succeeded"}, latest_command_run(latest_runs, "test"))

    no_attention? and compile_ok? and test_ok? and db_isolation != "unsafe"
  end

  defp latest_command_run(latest_runs, command_id) do
    Enum.find(latest_runs, &(&1.command_id == command_id))
  end

  defp normalize_active_run(nil), do: nil
  defp normalize_active_run(map) when is_map(map), do: normalize_run(map)
  defp normalize_active_run(_), do: nil

  defp normalize_run(map) when is_map(map) do
    %{
      id: field(map, "id") |> stringify(),
      command_id: (field(map, "command_id") || field(map, "id")) |> stringify(),
      status: field(map, "status") |> stringify(),
      exit_code: field(map, "exit_code") |> stringify(),
      duration_ms: field(map, "duration_ms"),
      started_at: field(map, "started_at") |> stringify(),
      finished_at: field(map, "finished_at") |> stringify()
    }
  end

  defp normalize_run(_), do: %{command_id: nil, status: nil}

  defp normalize_proposal(map) when is_map(map) do
    %{
      path: field(map, "path") |> stringify(),
      risk: field(map, "risk") |> stringify(),
      files_count: field(map, "files_count"),
      overlapping_files: map |> field("overlapping_files") |> normalize_string_list()
    }
  end

  defp normalize_proposal(_), do: %{path: nil, risk: nil, overlapping_files: []}

  defp proposal_risk?(%{risk: risk}), do: risk in @proposal_review_risks

  defp normalize_audit(map) when is_map(map) do
    %{
      action: field(map, "action") |> stringify(),
      target_type: field(map, "target_type") |> stringify(),
      target_ref: field(map, "target_ref") |> stringify(),
      decision: field(map, "decision") |> stringify(),
      reason: field(map, "reason") |> stringify(),
      inserted_at: field(map, "inserted_at") |> stringify()
    }
  end

  defp normalize_audit(_), do: %{action: nil}

  defp policy_block?(%{action: "policy.blocked"}), do: true
  defp policy_block?(_), do: false

  defp normalize_string_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_string_list(_), do: []

  defp fallback_list(nil, fallback), do: fallback_list(fallback, [])
  defp fallback_list(list, _fallback) when is_list(list), do: list
  defp fallback_list(_other, fallback) when is_list(fallback), do: fallback
  defp fallback_list(_other, _fallback), do: []

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)

  defp field(nil, _key), do: nil

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp field(_other, _key), do: nil
end
