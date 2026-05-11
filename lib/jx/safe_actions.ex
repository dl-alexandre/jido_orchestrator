defmodule JX.SafeActions do
  @moduledoc """
  Approval-gated safe action ledger.

  Proposed actions stay deterministic and policy-checked. Execution requires
  explicit confirmation and is limited to supported safe-action kinds.
  """

  alias JX.Approvals
  alias JX.Approvals.Approval
  alias JX.DevIDE.Client
  alias JX.DevIDE.WorkspaceSnapshot
  alias JX.OperationalEvents
  alias JX.OperationalLeases
  alias JX.OperationalLeases.Lease
  alias JX.OrchestrationActions
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Repo
  alias JX.SafeActions.{Action, Audit, Registry}
  alias JX.SafeActions.Kinds.RerunDevIDECommand

  @requested "actions.propose"
  @source "approval"
  @action_ttl_seconds 24 * 60 * 60

  @spec propose(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def propose(approval_id, opts \\ []) when is_binary(approval_id) do
    kind = Keyword.get(opts, :kind, Registry.default_kind())
    context = context(opts)

    with {:ok, kind_module} <- Registry.fetch(kind),
         %Approval{} = approval <- Approvals.get(approval_id),
         :ok <- OperationalLeases.authorize("approval", approval_id, Keyword.get(opts, :owner)),
         {:ok, safe_action} <- kind_module.propose(approval, context),
         {:ok, record} <-
           record_planned(safe_action, correlation_id: proposal_correlation_id(approval_id, opts)) do
      _ = Audit.record_once("proposed", Audit.attrs(record, safe_action))
      _ = OperationalEvents.record_action(record, "safe_action.proposed")
      {:ok, result(record, safe_action)}
    else
      nil -> {:error, :approval_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec dry_run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def dry_run(action_id, opts \\ []) when is_binary(action_id) do
    context = context(opts)

    with {:ok, kind_module, record, safe_action, approval, _snapshot} <-
           load_authorized(action_id, context),
         :ok <- authorize_leases(record, context) do
      case kind_module.dry_run(record, safe_action, approval, context) do
        {:ok, result} ->
          _ = OperationalEvents.record_action(record, "safe_action.dry_run_viewed")
          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, {:action_not_found, action_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec execute(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(action_id, opts \\ []) when is_binary(action_id) do
    if Keyword.get(opts, :confirm, false) do
      do_execute(action_id, opts)
    else
      _ = record_execute_denied(action_id, :confirmation_required)
      {:error, :confirmation_required}
    end
  end

  def allowed_commands, do: RerunDevIDECommand.allowed_commands()

  def show(action_id) when is_binary(action_id) do
    case Repo.get_by(OrchestrationAction, action_id: action_id) do
      %OrchestrationAction{} = record ->
        events = Audit.list_for_action(action_id)

        {:ok,
         %{
           action: record,
           payload: Audit.payload(record),
           events: events,
           guidance: operator_guidance(record, events)
         }}

      nil ->
        {:error, {:action_not_found, action_id}}
    end
  end

  def history(approval_id) when is_binary(approval_id) do
    events = Audit.list_for_approval(approval_id)
    actions = OrchestrationActions.list_actions(source: @source, ref: approval_id, limit: 100)

    {:ok,
     %{
       approval_id: approval_id,
       actions: actions,
       events: events,
       guidance: action_guidance(actions, events)
     }}
  end

  defp do_execute(action_id, opts) do
    context = context(opts)

    with {:ok, record} <- fetch_record(action_id),
         {:ok, kind_module} <- supported_record(record) do
      _ = Audit.record("execute_attempted", Audit.attrs(record))

      case authorize_for_execute(record, kind_module, context) do
        {:ok, safe_action, approval, _snapshot} ->
          context = with_action_correlation(context, record)

          case kind_module.execute(record, safe_action, approval, context) do
            {:ok, %{action: executed_record}} = result ->
              _ = OperationalEvents.record_action(executed_record, "safe_action.executed")
              result

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          _ = record_denied(record, reason)
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_authorized(action_id, context) do
    with {:ok, record} <- fetch_record(action_id),
         {:ok, kind_module} <- supported_record(record),
         {:ok, safe_action, approval, snapshot} <- authorize_record(record, kind_module, context) do
      {:ok, kind_module, record, safe_action, approval, snapshot}
    end
  end

  defp authorize_for_execute(%OrchestrationAction{} = record, kind_module, context) do
    with :ok <- executable_record(record),
         :ok <- authorize_leases(record, context),
         {:ok, safe_action, approval, snapshot} <- authorize_record(record, kind_module, context) do
      {:ok, safe_action, approval, snapshot}
    end
  end

  defp authorize_record(%OrchestrationAction{} = record, kind_module, context) do
    with %Approval{} = approval <- Approvals.get(record.ref),
         {:ok, safe_action, snapshot} <- kind_module.authorize(record, approval, context),
         :ok <- verify_record_match(record, safe_action, kind_module) do
      {:ok, safe_action, approval, snapshot}
    else
      nil -> {:error, {:approval_not_found, record.ref}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_planned(%Action{} = safe_action, opts) do
    correlation_id = Keyword.get(opts, :correlation_id) || correlation_id()

    decision =
      safe_action
      |> Action.to_decision()
      |> Map.put(:expires_at, expires_at())
      |> Map.put(:correlation_id, correlation_id)

    case OrchestrationActions.record_planned(@requested, [decision], source: @source) do
      %{records: [record], errors: []} -> {:ok, record}
      %{errors: [error | _rest]} -> {:error, error}
    end
  end

  defp record_result(decision) when is_map(decision) do
    case OrchestrationActions.record_result(@requested, decision, source: @source) do
      {:ok, record} -> {:ok, record}
      {:error, error} -> {:error, error}
    end
  end

  defp context(opts) do
    %{
      opts: opts,
      client: Keyword.get_lazy(opts, :client, &Client.new/0),
      stored_snapshot: &stored_snapshot/1,
      record_event: &Audit.record/2,
      record_result: &record_result/1,
      record_denied: &record_denied/4,
      acknowledge_approval: &acknowledge_approval/2,
      reason_text: &reason_text/1,
      result: &result/2
    }
  end

  defp with_action_correlation(context, %OrchestrationAction{} = record) do
    update_in(
      context,
      [:opts],
      &Keyword.put_new(&1, :correlation_id, Audit.correlation_id(record))
    )
  end

  defp fetch_record(action_id) do
    case Repo.get_by(OrchestrationAction, action_id: action_id) do
      %OrchestrationAction{} = record -> {:ok, record}
      nil -> {:error, {:action_not_found, action_id}}
    end
  end

  defp stored_snapshot(workspace_id) do
    case Repo.get_by(WorkspaceSnapshot, workspace_id: workspace_id) do
      %WorkspaceSnapshot{} = snapshot -> {:ok, snapshot}
      nil -> {:error, {:workspace_snapshot_not_found, workspace_id}}
    end
  end

  defp supported_record(%OrchestrationAction{action: action, source: @source}) do
    Registry.fetch(action)
  end

  defp supported_record(%OrchestrationAction{action: action}),
    do: {:error, {:unsupported_safe_action, action}}

  defp executable_record(%OrchestrationAction{status: "executed", action_id: action_id}),
    do: {:error, {:action_already_executed, action_id}}

  defp executable_record(%OrchestrationAction{status: "cancelled", action_id: action_id}),
    do: {:error, {:action_revoked, action_id}}

  defp executable_record(%OrchestrationAction{status: status})
       when status not in ["planned", "queued"] do
    {:error, {:action_not_executable, status}}
  end

  defp executable_record(%OrchestrationAction{} = record) do
    cond do
      revoked?(record) -> {:error, {:action_revoked, record.action_id}}
      expired?(record) -> {:error, {:action_expired, record.action_id}}
      true -> :ok
    end
  end

  defp verify_record_match(%OrchestrationAction{} = record, %Action{} = safe_action, kind_module) do
    payload = Audit.payload(record)

    expected = kind_module.expected_fields(safe_action)

    mismatched? =
      Enum.any?(expected, fn {key, expected_value} ->
        payload_value = field(payload, key)
        present?(payload_value) and to_string(payload_value) != expected_value
      end)

    if mismatched?,
      do: {:error, {:approval_mismatch, record.action_id}},
      else: :ok
  end

  defp result(%OrchestrationAction{} = record, %Action{} = safe_action) do
    %{
      action: record,
      safe_action: Action.to_map(safe_action),
      would_do: Action.would_do(safe_action),
      dry_run_only: false,
      executed: false,
      mode: "planned"
    }
  end

  defp record_execute_denied(action_id, reason) do
    with {:ok, record} <- fetch_record(action_id),
         {:ok, _kind_module} <- supported_record(record) do
      record_denied(record, reason)
    end
  end

  defp record_denied(%OrchestrationAction{} = record, reason, safe_action \\ nil, opts \\ []) do
    attrs =
      case safe_action do
        %Action{} -> Audit.attrs(record, safe_action)
        _other -> Audit.attrs(record)
      end

    Audit.record(
      "execute_denied",
      attrs
      |> Map.put(:outcome, Keyword.get(opts, :outcome, denial_outcome(reason)))
      |> Map.put(:reason, reason_text(reason))
      |> Map.put(:payload, %{
        reason: reason_payload(reason),
        devide_response: Keyword.get(opts, :envelope)
      })
    )
    |> tap(fn _event ->
      outcome = Keyword.get(opts, :outcome, denial_outcome(reason))

      _ =
        OperationalEvents.record_action(record, "safe_action.execute_denied",
          severity: "warning",
          summary: "safe action #{record.action_id} denied: #{reason_text(reason)}",
          payload: %{
            "denial" => %{
              "outcome" => outcome,
              "reason" => reason_text(reason),
              "payload" => reason_payload(reason)
            }
          }
        )
    end)
  end

  defp authorize_leases(%OrchestrationAction{} = record, context) do
    owner = context |> Map.fetch!(:opts) |> Keyword.get(:owner)

    with :ok <- OperationalLeases.authorize("approval", record.ref, owner),
         :ok <- OperationalLeases.authorize("action", record.action_id, owner) do
      :ok
    end
  end

  defp acknowledge_approval(approval_id, opts) do
    case Keyword.get(opts, :acknowledge_fun) do
      fun when is_function(fun, 1) ->
        case fun.(approval_id) do
          {:ok, approval} -> {:ok, approval}
          {:error, reason} -> {:error, {:approval_ack_failed, reason}}
        end

      _other ->
        case Approvals.acknowledge(approval_id,
               correlation_id: Keyword.get(opts, :correlation_id)
             ) do
          {:ok, approval} -> {:ok, approval}
          {:error, reason} -> {:error, {:approval_ack_failed, reason}}
        end
    end
  end

  defp revoked?(%OrchestrationAction{} = record) do
    payload = Audit.payload(record)
    truthy?(field(payload, "revoked")) or present?(field(payload, "revoked_at"))
  end

  defp expired?(%OrchestrationAction{} = record) do
    case field(Audit.payload(record), "expires_at") do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, expires_at, _offset} -> DateTime.compare(DateTime.utc_now(), expires_at) == :gt
          _other -> false
        end

      _other ->
        false
    end
  end

  defp expires_at do
    DateTime.utc_now()
    |> DateTime.add(@action_ttl_seconds, :second)
    |> DateTime.to_iso8601()
  end

  defp reason_payload(%Client.Error{} = error) do
    %{reason: Atom.to_string(error.reason), status: error.status, message: error.message}
  end

  defp reason_payload(reason), do: inspect(reason)

  defp reason_text(%Client.Error{} = error), do: Client.format_error(error)
  defp reason_text(reason), do: inspect(reason)

  defp denial_outcome(%Client.Error{status: nil}), do: "network_failure"
  defp denial_outcome(%Client.Error{}), do: "devide_failure"
  defp denial_outcome({:malformed_devide_response, _reason}), do: "malformed_response"
  defp denial_outcome({:approval_ack_failed, _reason}), do: "approval_ack_failure"
  defp denial_outcome(:confirmation_required), do: "confirmation_required"
  defp denial_outcome({:action_already_executed, _action_id}), do: "replay_denied"
  defp denial_outcome({:action_not_executable, "executed"}), do: "replay_denied"
  defp denial_outcome(_reason), do: "policy_denied"

  defp correlation_id do
    random =
      8
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    "corr-" <> random
  end

  defp proposal_correlation_id(approval_id, opts) do
    owner = opts |> Keyword.get(:owner) |> normalize_text()

    case OperationalLeases.active("approval", approval_id) do
      %Lease{owner: ^owner, correlation_id: correlation_id} ->
        text_present(correlation_id) || Keyword.get(opts, :correlation_id)

      _other ->
        Keyword.get(opts, :correlation_id)
    end
  end

  defp text_present(value) when value in [nil, ""], do: nil
  defp text_present(value), do: value

  defp normalize_text(nil), do: ""
  defp normalize_text(value), do: value |> to_string() |> String.trim()

  defp truthy?(value), do: value in [true, "true", 1, "1", "yes"]

  defp present?(value), do: value not in [nil, ""]

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp field(_map, _key), do: nil

  defp operator_guidance(%OrchestrationAction{} = action, events) do
    latest_outcome =
      events
      |> List.last()
      |> case do
        nil -> ""
        event -> event.outcome
      end

    case Registry.fetch(action.action) do
      {:ok, kind_module} ->
        kind_module.recovery_guidance(action, events, latest_outcome)

      {:error, _reason} ->
        "Refresh state and repropose from a current approval if the action is still needed."
    end
  end

  defp action_guidance(actions, events) do
    Map.new(actions, fn action ->
      events_for_action = Enum.filter(events, &(&1.action_id == action.action_id))
      {action.action_id, operator_guidance(action, events_for_action)}
    end)
  end
end
