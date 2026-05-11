defmodule JX.OperationExecutions do
  @moduledoc """
  Persistence operations for operator execution audit records.
  """

  import Ecto.Query

  alias JX.OperationExecutions.OperationExecution
  alias JX.Repo

  def audit_results(requested, results) do
    case insert_results(requested, results) do
      {:ok, records} -> %{saved: length(records), errors: []}
      {:error, reason} -> %{saved: 0, errors: [inspect(reason)]}
    end
  end

  def list_executions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    OperationExecution
    |> maybe_filter_ref(Keyword.get(opts, :ref))
    |> maybe_filter_action(Keyword.get(opts, :action))
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> order_by([execution], desc: execution.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp insert_results(requested, results) do
    Repo.transaction(fn ->
      Enum.map(results, fn result ->
        attrs = execution_attrs(requested, result)

        %OperationExecution{}
        |> OperationExecution.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, execution} -> execution
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  defp execution_attrs(requested, result) do
    %{
      execution_id: execution_id(),
      requested: requested || "",
      recommendation_id: Map.get(result, :id, ""),
      action: Map.get(result, :action) || "",
      safety: Map.get(result, :safety) || "",
      ref: Map.get(result, :ref, ""),
      target: Map.get(result, :target, ""),
      status: Map.fetch!(result, :status),
      reason: Map.get(result, :reason, ""),
      error: Map.get(result, :error, ""),
      result_summary: result_summary(result),
      result_snapshot: encode_result(result)
    }
  end

  defp result_summary(%{probe: probe}), do: probe_summary(probe)
  defp result_summary(%{capture: %{summary: summary}}), do: summary
  defp result_summary(%{result_summary: summary}), do: summary
  defp result_summary(%{error: error}), do: error
  defp result_summary(%{reason: reason}), do: reason
  defp result_summary(_result), do: ""

  defp probe_summary(probe) do
    tmux = Map.get(probe, :tmux, "unknown")
    sessions = Map.get(probe, :sessions, 0)
    "tmux #{tmux}; sessions #{sessions}"
  end

  defp encode_result(result) do
    result
    |> audit_result()
    |> Jason.encode!()
  rescue
    Protocol.UndefinedError -> inspect(result)
    ArgumentError -> inspect(result)
  end

  defp audit_result(%{capture: %{output: output} = capture} = result) when is_binary(output) do
    capture =
      capture
      |> Map.delete(:output)
      |> Map.put(:output_redacted, true)
      |> Map.put(:output_bytes, byte_size(output))

    Map.put(result, :capture, capture)
  end

  defp audit_result(result), do: result

  defp maybe_filter_ref(query, nil), do: query
  defp maybe_filter_ref(query, ref), do: where(query, [execution], execution.ref == ^ref)

  defp maybe_filter_action(query, nil), do: query

  defp maybe_filter_action(query, action),
    do: where(query, [execution], execution.action == ^action)

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status),
    do: where(query, [execution], execution.status == ^status)

  defp execution_id do
    random =
      5
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    "opx-" <> random
  end
end
