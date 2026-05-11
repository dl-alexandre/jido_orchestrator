defmodule JX.SafeActions.Audit do
  @moduledoc """
  Append-only audit trail for approval-gated safe actions.
  """

  import Ecto.Query

  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Repo
  alias JX.SafeActions.{Action, ExecutionEvent}

  @event_prefix "sae-"

  def record_once(kind, attrs) when is_binary(kind) do
    case existing(kind, attrs) do
      %ExecutionEvent{} = event -> {:ok, event}
      nil -> record(kind, attrs)
    end
  end

  def record(kind, attrs) when is_binary(kind) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:event_id, event_id())
      |> Map.put(:kind, kind)
      |> Map.put_new(:outcome, default_outcome(kind))
      |> Map.update(:correlation_id, correlation_id_from_attrs(attrs), &normalize_text/1)
      |> Map.update(:payload, "{}", &encode_payload/1)
      |> Map.update(:reason, "", &reason_text/1)

    %ExecutionEvent{}
    |> ExecutionEvent.changeset(attrs)
    |> Repo.insert()
  end

  def list_for_action(action_id) when is_binary(action_id) do
    ExecutionEvent
    |> where([event], event.action_id == ^action_id)
    |> order_by([event], asc: event.id)
    |> Repo.all()
  end

  def list_for_approval(approval_id) when is_binary(approval_id) do
    ExecutionEvent
    |> where([event], event.approval_id == ^approval_id)
    |> order_by([event], asc: event.id)
    |> Repo.all()
  end

  def attrs(%OrchestrationAction{} = record) do
    action = payload(record)

    %{
      action_id: record.action_id,
      correlation_id: correlation_id(record),
      approval_id: record.ref,
      workspace_id: text_field(action, "workspace_id"),
      command_id: text_field(action, "command_id"),
      payload: %{
        action_id: record.action_id,
        status: record.status,
        ref: record.ref,
        target: record.target,
        payload: action
      }
    }
  end

  def attrs(%OrchestrationAction{} = record, %Action{} = safe_action) do
    record
    |> attrs()
    |> Map.merge(%{
      approval_id: safe_action.approval_id,
      workspace_id: safe_action.workspace_id,
      command_id: safe_action.command_id
    })
  end

  def payload(%OrchestrationAction{payload: payload}) do
    case Jason.decode(payload || "{}") do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{}
    end
  end

  def correlation_id(%OrchestrationAction{} = record) do
    record
    |> payload()
    |> text_field("correlation_id")
  end

  defp existing(kind, attrs) do
    action_id = Map.get(attrs, :action_id) || Map.get(attrs, "action_id")

    ExecutionEvent
    |> where([event], event.action_id == ^action_id and event.kind == ^kind)
    |> order_by([event], asc: event.id)
    |> limit(1)
    |> Repo.one()
  end

  defp default_outcome("proposed"), do: "proposed"
  defp default_outcome("dry_run_viewed"), do: "dry_run_viewed"
  defp default_outcome("execute_attempted"), do: "execute_attempted"
  defp default_outcome("executed"), do: "success"
  defp default_outcome("approval_ack_attempted"), do: "execute_attempted"
  defp default_outcome("approval_acknowledged"), do: "approval_acknowledged"
  defp default_outcome("execute_denied"), do: "policy_denied"
  defp default_outcome(_kind), do: "policy_denied"

  defp correlation_id_from_attrs(attrs) do
    attrs = Map.new(attrs)

    attrs
    |> Map.get(:correlation_id, Map.get(attrs, "correlation_id"))
    |> normalize_text()
  end

  defp encode_payload(payload) when is_binary(payload), do: payload
  defp encode_payload(payload), do: Jason.encode!(payload)

  defp reason_text(value) when is_binary(value), do: value
  defp reason_text(value), do: inspect(value)

  defp normalize_text(nil), do: ""
  defp normalize_text(value), do: value |> to_string() |> String.trim()

  defp text_field(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      nil -> ""
      value -> to_string(value)
    end
  end

  defp event_id do
    random =
      5
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    @event_prefix <> random
  end
end
