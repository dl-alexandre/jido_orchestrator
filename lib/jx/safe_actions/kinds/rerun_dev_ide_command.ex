defmodule JX.SafeActions.Kinds.RerunDevIDECommand do
  @moduledoc """
  Approval-gated DevIDE command rerun safe-action kind.
  """

  @behaviour JX.SafeActions.Kind

  alias JX.Approvals.Approval
  alias JX.DevIDE.{Client, WorkspaceSnapshot}
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.SafeActions.{Action, Audit}

  @kind "rerun_devide_command"
  @allowed_commands ~w(compile test format precommit)
  @allowed_db_isolations ~w(local ephemeral unknown)
  @blocked_db_isolations ~w(shared_stage unsafe)

  @impl true
  def kind, do: @kind

  def allowed_commands, do: @allowed_commands
  def allowed_db_isolations, do: @allowed_db_isolations
  def blocked_db_isolations, do: @blocked_db_isolations

  @impl true
  def propose(%Approval{} = approval, context) do
    with {:ok, snapshot} <- stored_snapshot(context, approval.workspace_id) do
      authorize_action(approval, snapshot)
    end
  end

  @impl true
  def authorize(%OrchestrationAction{}, %Approval{} = approval, context) do
    with {:ok, snapshot} <- stored_snapshot(context, approval.workspace_id),
         {:ok, safe_action} <- authorize_action(approval, snapshot) do
      {:ok, safe_action, snapshot}
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
    correlation_id = Audit.correlation_id(record)

    case Client.start_run_envelope(
           client(context),
           safe_action.workspace_id,
           safe_action.command_id,
           correlation_id: correlation_id
         ) do
      {:ok, envelope} ->
        with {:ok, envelope} <- validate_run_envelope(envelope, safe_action),
             {:ok, executed_record} <- record_executed(context, safe_action, envelope),
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
                       envelope: envelope
                     })
                 })
               ),
             {:ok, _event} <-
               record_event(
                 context,
                 "approval_ack_attempted",
                 executed_record
                 |> Audit.attrs(safe_action)
                 |> Map.put(
                   :payload,
                   audit_payload("approval_ack_attempted", executed_record, safe_action, %{
                     approval: approval,
                     envelope: envelope
                   })
                 )
               ),
             {:ok, acknowledged} <- acknowledge_approval(context, approval.approval_id),
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
                       approval: acknowledged,
                       envelope: envelope
                     })
                 })
               ) do
          {:ok,
           result(context, executed_record, safe_action)
           |> Map.put(:mode, "executed")
           |> Map.put(:executed, true)
           |> Map.put(:run, response_body(envelope))
           |> Map.put(:devide_response, envelope)
           |> Map.put(:approval, acknowledged)
           |> Map.put(:previous_action, record)}
        else
          {:error, {:malformed_devide_response, _reason} = reason} ->
            _ = record_action_error(context, safe_action, "malformed_response", reason, envelope)

            _ =
              record_denied(context, record, reason, safe_action,
                outcome: "malformed_response",
                envelope: envelope
              )

            {:error, reason}

          {:error, {:approval_ack_failed, _reason} = reason} ->
            _ =
              record_denied(context, record, reason, safe_action,
                outcome: "approval_ack_failure",
                envelope: envelope
              )

            {:error, reason}

          {:error, reason} ->
            _ = record_denied(context, record, reason, safe_action, [])
            {:error, reason}
        end

      {:error, reason} ->
        _ = record_denied(context, record, reason, safe_action, [])
        {:error, reason}
    end
  end

  @impl true
  def target(%Action{} = action), do: "#{action.workspace_id}:#{action.command_id}"

  @impl true
  def would_do(%Action{} = action) do
    "would request DevIDE to rerun allowlisted command #{action.command_id} " <>
      "for workspace #{action.workspace_id} via POST /api/workspaces/#{action.workspace_id}/runs"
  end

  @impl true
  def contract(%Action{}), do: "M30 approval-gated DevIDE command rerun"

  @impl true
  def expected_fields(%Action{} = safe_action) do
    %{
      "approval_id" => safe_action.approval_id,
      "workspace_id" => safe_action.workspace_id,
      "command_id" => safe_action.command_id,
      "target" => target(safe_action),
      "ref" => safe_action.approval_id
    }
  end

  @impl true
  def audit_payload("executed", %OrchestrationAction{}, %Action{}, %{envelope: envelope}) do
    %{devide_response: envelope}
  end

  def audit_payload(
        "approval_ack_attempted",
        %OrchestrationAction{},
        %Action{},
        %{approval: %Approval{} = approval, envelope: envelope}
      ) do
    %{approval_id: approval.approval_id, devide_response: envelope}
  end

  def audit_payload(
        "approval_acknowledged",
        %OrchestrationAction{},
        %Action{},
        %{approval: %Approval{} = approval, envelope: envelope}
      ) do
    %{approval_id: approval.approval_id, devide_response: envelope}
  end

  def audit_payload(_kind, %OrchestrationAction{}, %Action{}, context) do
    Map.get(context, :payload, %{})
  end

  @impl true
  def recovery_guidance(%OrchestrationAction{} = action, _events, latest_outcome) do
    cond do
      latest_outcome == "approval_ack_failure" ->
        "Inspect DevIDE for the run result, then acknowledge or dismiss the approval manually. Do not retry this action; repropose only if new evidence creates a new approval."

      action.status == "executed" ->
        "No retry: this action already executed. Inspect DevIDE if the run outcome is unclear; repropose only from new approval evidence."

      latest_outcome == "network_failure" ->
        "Retry this action with `jx actions execute #{action.action_id} --confirm` after checking DevIDE connectivity."

      latest_outcome == "devide_failure" ->
        "Inspect DevIDE status and audit for #{action.target}; retry this action after the DevIDE-side failure is resolved."

      latest_outcome == "malformed_response" ->
        "Inspect DevIDE for a possible started run before doing anything else. Repropose from fresh approval evidence if the stored action is stale."

      latest_outcome == "confirmation_required" ->
        "Retry with `jx actions execute #{action.action_id} --confirm` after reviewing the dry-run output."

      latest_outcome in ["policy_denied", "replay_denied"] or
          action.status in ["error", "cancelled"] ->
        "Refresh DevIDE state and repropose from a current approval if the action is still needed."

      true ->
        "Retry with `jx actions execute #{action.action_id} --confirm`, or run `jx actions dry-run #{action.action_id}` first."
    end
  end

  defp authorize_action(%Approval{} = approval, %WorkspaceSnapshot{} = snapshot) do
    command_id = approval |> command_id() |> normalize_text()
    db_isolation = snapshot.db_isolation |> normalize_db_isolation()

    cond do
      approval.status not in Approval.active_statuses() ->
        {:error, {:approval_not_active, approval.status}}

      approval.kind != "failed_run" ->
        {:error, {:unsupported_approval_kind, approval.kind}}

      snapshot.workspace_id != approval.workspace_id ->
        {:error, {:workspace_mismatch, approval.workspace_id, snapshot.workspace_id}}

      db_isolation in @blocked_db_isolations ->
        {:error, {:unsafe_db_isolation, db_isolation}}

      db_isolation not in @allowed_db_isolations ->
        {:error, {:unsupported_db_isolation, db_isolation}}

      command_id not in @allowed_commands ->
        {:error, {:unsupported_devide_command, command_id, @allowed_commands}}

      true ->
        {:ok,
         %Action{
           approval_id: approval.approval_id,
           workspace_id: approval.workspace_id,
           command_id: command_id,
           db_isolation: db_isolation,
           target_ref: approval.target_ref
         }}
    end
  end

  defp record_executed(context, %Action{} = safe_action, envelope) do
    decision =
      safe_action
      |> Action.to_decision()
      |> Map.merge(%{
        status: "executed",
        correlation_id: Map.get(envelope, :correlation_id, ""),
        result_summary: run_summary(envelope),
        run: response_body(envelope),
        devide_response: envelope
      })

    record_result(context, decision)
  end

  defp record_action_error(context, %Action{} = safe_action, outcome, reason, envelope) do
    decision =
      safe_action
      |> Action.to_decision()
      |> Map.merge(%{
        status: "error",
        correlation_id: Map.get(envelope, :correlation_id, ""),
        error: reason_text(context, reason),
        result_summary: reason_text(context, reason),
        outcome: "failed",
        outcome_reason: outcome,
        devide_response: envelope
      })

    record_result(context, decision)
  end

  defp validate_run_envelope(%{body: body} = envelope, %Action{} = safe_action)
       when is_map(body) do
    cond do
      not present?(field(body, "id")) ->
        {:error, {:malformed_devide_response, :missing_run_id}}

      not present?(field(body, "status")) ->
        {:error, {:malformed_devide_response, :missing_status}}

      present?(field(body, "command_id")) and field(body, "command_id") != safe_action.command_id ->
        {:error, {:malformed_devide_response, :command_mismatch}}

      true ->
        {:ok, envelope}
    end
  end

  defp validate_run_envelope(_envelope, _safe_action),
    do: {:error, {:malformed_devide_response, :non_map_body}}

  defp run_summary(envelope) when is_map(envelope) do
    run = response_body(envelope)
    run_id = field(run, "id") || "unknown"
    status = field(run, "status") || "unknown"
    command_id = field(run, "command_id") || "command"
    "DevIDE run #{run_id} #{command_id} #{status}"
  end

  defp command_id(%Approval{} = approval) do
    metadata = decode_json(approval.metadata, %{})
    run = field(metadata, "run") || %{}

    first_present([
      field(run, "command_id"),
      field(run, "id"),
      approval.target_ref
    ])
  end

  defp normalize_db_isolation(value) do
    case normalize_text(value) do
      "" -> "unknown"
      value -> value
    end
  end

  defp normalize_text(nil), do: ""
  defp normalize_text(value), do: value |> to_string() |> String.trim()

  defp decode_json(text, fallback) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> fallback
    end
  end

  defp decode_json(_text, fallback), do: fallback

  defp first_present(values) do
    Enum.find_value(values, "", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      nil ->
        nil

      value ->
        value |> to_string() |> String.trim() |> present_or_nil()
    end)
  end

  defp present_or_nil(""), do: nil
  defp present_or_nil(value), do: value

  defp stored_snapshot(context, workspace_id) do
    context
    |> Map.fetch!(:stored_snapshot)
    |> then(& &1.(workspace_id))
  end

  defp client(context), do: Map.fetch!(context, :client)

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

  defp reason_text(context, reason) do
    context
    |> Map.fetch!(:reason_text)
    |> then(& &1.(reason))
  end

  defp response_body(%{body: body}), do: body
  defp response_body(body), do: body

  defp present?(value), do: value not in [nil, ""]

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp field(_map, _key), do: nil
end
