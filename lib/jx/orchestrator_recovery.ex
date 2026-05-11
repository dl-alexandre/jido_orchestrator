defmodule JX.OrchestratorRecovery do
  @moduledoc """
  Builds explicit recovery recommendations from session reconciliation.

  The recovery plan is intentionally descriptive. It names the reattach,
  duplicate, and corrupted-observation cases the orchestrator can see without
  mutating sessions by itself.
  """

  def build(reconciliation, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    recommendations =
      []
      |> add_orphan_remote(reconciliation)
      |> add_local_without_remote(reconciliation)
      |> add_duplicate_paths(reconciliation)
      |> add_errors(reconciliation)
      |> Enum.reverse()
      |> Enum.take(limit)

    %{
      generated_at: DateTime.utc_now(),
      status: if(recommendations == [], do: "ok", else: "needs_recovery"),
      recommendations_total: length(recommendations),
      recommendations: recommendations,
      counts: %{
        orphan_remote: get_in(reconciliation, [:totals, :orphan_remote]) || 0,
        local_without_remote: get_in(reconciliation, [:totals, :local_without_remote]) || 0,
        duplicate_paths: get_in(reconciliation, [:totals, :duplicate_paths]) || 0,
        errors: length(Map.get(reconciliation, :errors, []))
      }
    }
  end

  defp add_orphan_remote(recommendations, reconciliation) do
    reconciliation
    |> Map.get(:orphan_remote, [])
    |> Enum.reduce(recommendations, fn remote, acc ->
      [
        %{
          action: "reattach-remote-session",
          safety: "manual",
          ref: Map.get(remote, :local_ref, ""),
          target: remote_target(remote),
          reason: "remote tmux session has no matching local profile",
          evidence:
            compact([Map.get(remote, :current_path, ""), Map.get(remote, :ssh_target, "")])
        }
        | acc
      ]
    end)
  end

  defp add_local_without_remote(recommendations, reconciliation) do
    reconciliation
    |> Map.get(:local_without_remote, [])
    |> Enum.reject(&(Map.get(&1, :state, "") in ["done", "parked"]))
    |> Enum.reduce(recommendations, fn local, acc ->
      [
        %{
          action: "recover-local-session",
          safety: "manual",
          ref: Map.get(local, :ref, ""),
          target: Map.get(local, :pane, ""),
          reason: "local profile has no matching remote observation",
          evidence: compact([Map.get(local, :path, ""), Map.get(local, :next_step, "")])
        }
        | acc
      ]
    end)
  end

  defp add_duplicate_paths(recommendations, reconciliation) do
    reconciliation
    |> Map.get(:duplicate_paths, [])
    |> Enum.reduce(recommendations, fn duplicate, acc ->
      [
        %{
          action: "resolve-duplicate-session-path",
          safety: "manual",
          ref: duplicate |> Map.get(:refs, []) |> Enum.join(","),
          target: Map.get(duplicate, :path, ""),
          reason: "multiple local sessions report the same working directory",
          evidence: compact(Map.get(duplicate, :projects, []))
        }
        | acc
      ]
    end)
  end

  defp add_errors(recommendations, reconciliation) do
    reconciliation
    |> Map.get(:errors, [])
    |> Enum.reduce(recommendations, fn error, acc ->
      [
        %{
          action: "inspect-corrupt-observation",
          safety: "inspect",
          ref: "",
          target: "",
          reason: inspect(error),
          evidence: []
        }
        | acc
      ]
    end)
  end

  defp remote_target(remote) do
    [
      Map.get(remote, :ssh_target, ""),
      Map.get(remote, :tmux_server, ""),
      Map.get(remote, :session_name, "")
    ]
    |> compact()
    |> Enum.join("/")
  end

  defp compact(values) do
    values
    |> List.wrap()
    |> Enum.map(&stringify/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp stringify(value) when is_binary(value), do: String.trim(value)
  defp stringify(nil), do: ""
  defp stringify(value), do: to_string(value)
end
