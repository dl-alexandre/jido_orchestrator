defmodule JX.SafeActions.Kinds.AcknowledgeApproval do
  @moduledoc """
  JX-only approval acknowledgment safe-action kind.
  """

  @behaviour JX.SafeActions.Kind

  alias JX.Approvals.Approval
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.SafeActions.{Action, Audit}

  @kind "acknowledge_approval"
  @reason "approval-gated JX approval acknowledgment"

  @impl true
  def kind, do: @kind

  @impl true
  def propose(%Approval{} = approval, _context), do: authorize_action(approval)

  @impl true
  def authorize(%OrchestrationAction{}, %Approval{} = approval, _context) do
    with {:ok, safe_action} <- authorize_action(approval) do
      {:ok, safe_action, nil}
    end
  end

  @impl true
  def dry_run(%OrchestrationAction{} = record, %Action{} = safe_action, %Approval{}, context) do
    _ = record_event(context, "dry_run_viewed", Audit.attrs(record, safe_action))

    {:ok,
     result(context, record, safe_action)
     |> Map.put(:mode, "dry_run")
     |> Map.put(:executed, false)}
  end

  @impl true
  def execute(
        %OrchestrationAction{} = record,
        %Action{} = safe_action,
        %Approval{} = approval,
        context
      ) do
    with {:ok, _event} <-
           record_event(
             context,
             "approval_ack_attempted",
             record
             |> Audit.attrs(safe_action)
             |> Map.put(
               :payload,
               audit_payload("approval_ack_attempted", record, safe_action, %{
                 approval: approval
               })
             )
           ),
         {:ok, acknowledged} <- acknowledge_approval(context, approval.approval_id),
         {:ok, executed_record} <-
           record_acknowledgment_executed(context, record, safe_action, acknowledged),
         {:ok, _event} <-
           record_event(
             context,
             "executed",
             executed_record
             |> Audit.attrs(safe_action)
             |> Map.merge(%{
               outcome: "success",
               payload:
                 audit_payload("executed", executed_record, safe_action, %{
                   approval: acknowledged
                 })
             })
           ),
         {:ok, _event} <-
           record_event(
             context,
             "approval_acknowledged",
             executed_record
             |> Audit.attrs(safe_action)
             |> Map.merge(%{
               outcome: "approval_acknowledged",
               payload:
                 audit_payload("approval_acknowledged", executed_record, safe_action, %{
                   approval: acknowledged
                 })
             })
           ) do
      {:ok,
       result(context, executed_record, safe_action)
       |> Map.put(:mode, "executed")
       |> Map.put(:executed, true)
       |> Map.put(:approval, acknowledged)
       |> Map.put(:previous_action, record)}
    else
      {:error, {:approval_ack_failed, _reason} = reason} ->
        _ = record_denied(context, record, reason, safe_action, outcome: "approval_ack_failure")
        {:error, reason}

      {:error, reason} ->
        _ = record_denied(context, record, reason, safe_action, [])
        {:error, reason}
    end
  end

  @impl true
  def target(%Action{} = action), do: "#{action.workspace_id}:#{action.approval_id}"

  @impl true
  def would_do(%Action{} = action) do
    "would acknowledge JX approval #{action.approval_id} for workspace #{action.workspace_id} " <>
      "without calling DevIDE"
  end

  @impl true
  def contract(%Action{}), do: "M33 approval-gated JX approval acknowledgment"

  @impl true
  def expected_fields(%Action{} = safe_action) do
    %{
      "approval_id" => safe_action.approval_id,
      "workspace_id" => safe_action.workspace_id,
      "target" => target(safe_action),
      "ref" => safe_action.approval_id
    }
  end

  @impl true
  def audit_payload(
        event_kind,
        %OrchestrationAction{},
        %Action{},
        %{approval: %Approval{} = approval}
      )
      when event_kind in ["approval_ack_attempted", "executed", "approval_acknowledged"] do
    %{approval_id: approval.approval_id, status: approval.status}
  end

  def audit_payload(_kind, %OrchestrationAction{}, %Action{}, context) do
    Map.get(context, :payload, %{})
  end

  @impl true
  def recovery_guidance(%OrchestrationAction{} = action, _events, latest_outcome) do
    cond do
      latest_outcome == "approval_ack_failure" ->
        "Retry this action after checking JX state storage, or acknowledge the approval manually and repropose only from new approval evidence."

      action.status == "executed" ->
        "No retry: this approval acknowledgment already executed. Repropose only if a new approval is created."

      latest_outcome == "confirmation_required" ->
        "Retry with `jx actions execute #{action.action_id} --confirm` after reviewing the dry-run output."

      latest_outcome in ["policy_denied", "replay_denied"] or
          action.status in ["error", "cancelled"] ->
        "Refresh DevIDE state and repropose from a current approval if the action is still needed."

      true ->
        "Retry with `jx actions execute #{action.action_id} --confirm`, or run `jx actions dry-run #{action.action_id}` first."
    end
  end

  defp authorize_action(%Approval{} = approval) do
    cond do
      approval.status != "open" ->
        {:error, {:approval_not_open, approval.status}}

      approval.source != "devide" ->
        {:error, {:unsupported_approval_source, approval.source}}

      true ->
        {:ok,
         %Action{
           kind: @kind,
           approval_id: approval.approval_id,
           workspace_id: approval.workspace_id,
           command_id: "",
           db_isolation: "unknown",
           target_ref: approval.target_ref,
           reason: @reason
         }}
    end
  end

  defp record_acknowledgment_executed(
         context,
         %OrchestrationAction{} = record,
         %Action{} = safe_action,
         %Approval{} = approval
       ) do
    decision =
      safe_action
      |> Action.to_decision()
      |> Map.merge(%{
        status: "executed",
        correlation_id: Audit.correlation_id(record),
        result_summary: "JX approval #{approval.approval_id} #{approval.status}",
        approval: %{
          approval_id: approval.approval_id,
          status: approval.status
        }
      })

    record_result(context, decision)
  end

  defp result(context, record, safe_action) do
    context
    |> Map.fetch!(:result)
    |> then(& &1.(record, safe_action))
  end

  defp record_event(context, kind, attrs) do
    context
    |> Map.fetch!(:record_event)
    |> then(& &1.(kind, attrs))
  end

  defp record_result(context, decision) do
    context
    |> Map.fetch!(:record_result)
    |> then(& &1.(decision))
  end

  defp record_denied(context, record, reason, safe_action, opts) do
    context
    |> Map.fetch!(:record_denied)
    |> then(& &1.(record, reason, safe_action, opts))
  end

  defp acknowledge_approval(context, approval_id) do
    context
    |> Map.fetch!(:acknowledge_approval)
    |> then(& &1.(approval_id, Map.fetch!(context, :opts)))
  end
end
