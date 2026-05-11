defmodule JX.OperationalEvents do
  @moduledoc """
  Append-only operational evidence plane.

  This module records normalized events for the operator control plane. It does
  not execute work, call DevIDE, or mutate workspace state.
  """

  import Ecto.Query

  alias JX.Approvals.Approval
  alias JX.DevIDE.WorkspaceSnapshot
  alias JX.OperationalEvents.Event
  alias JX.OperationalLeases.Lease
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Repo

  @event_prefix "ope-"
  @correlation_prefix "corr-"

  @spec record(map() | keyword()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:event_id, event_id())
      |> Map.put_new(:correlation_id, correlation_id())
      |> Map.put_new(:source, "jx")
      |> Map.put_new(:severity, "info")
      |> Map.put_new(:summary, "")
      |> Map.put_new(:payload, %{})
      |> Map.update!(:payload, &encode_payload/1)

    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  @spec record_once(map() | keyword()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def record_once(attrs) do
    attrs = Map.new(attrs)

    case Map.get(attrs, :event_id) || Map.get(attrs, "event_id") do
      event_id when is_binary(event_id) and event_id != "" ->
        case Repo.get_by(Event, event_id: event_id) do
          %Event{} = event ->
            {:ok, event}

          nil ->
            case record(attrs) do
              {:ok, event} ->
                {:ok, event}

              {:error, %Ecto.Changeset{errors: errors} = changeset} ->
                if Keyword.has_key?(errors, :event_id) do
                  {:ok, Repo.get_by!(Event, event_id: event_id)}
                else
                  {:error, changeset}
                end
            end
        end

      _other ->
        record(attrs)
    end
  end

  def record!(attrs) do
    case record(attrs) do
      {:ok, event} -> event
      {:error, changeset} -> raise "operational event failed: #{inspect(changeset.errors)}"
    end
  end

  def record_many(events) when is_list(events), do: Enum.map(events, &record/1)

  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Event
    |> maybe_filter_kind(Keyword.get(opts, :kind))
    |> maybe_filter_entity(Keyword.get(opts, :entity_type), Keyword.get(opts, :entity_id))
    |> maybe_filter_workspace(Keyword.get(opts, :workspace_id))
    |> maybe_filter_approval(Keyword.get(opts, :approval_id))
    |> maybe_filter_action(Keyword.get(opts, :action_id))
    |> maybe_filter_lease(Keyword.get(opts, :lease_id))
    |> maybe_filter_correlation(Keyword.get(opts, :correlation_id))
    |> order_by([event], asc: event.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def timeline(scope, id, opts \\ [])

  def timeline(:workspace, workspace_id, opts),
    do:
      list(Keyword.merge(opts, workspace_id: workspace_id, limit: Keyword.get(opts, :limit, 100)))

  def timeline(:approval, approval_id, opts),
    do: list(Keyword.merge(opts, approval_id: approval_id, limit: Keyword.get(opts, :limit, 100)))

  def timeline(:action, action_id, opts),
    do: list(Keyword.merge(opts, action_id: action_id, limit: Keyword.get(opts, :limit, 100)))

  def timeline(:assignment, assignment_id, opts),
    do:
      list(
        Keyword.merge(opts,
          entity_type: "assignment",
          entity_id: assignment_id,
          limit: Keyword.get(opts, :limit, 100)
        )
      )

  def timeline(:session, session_id, opts),
    do:
      list(
        Keyword.merge(opts,
          entity_type: "runner_session",
          entity_id: session_id,
          limit: Keyword.get(opts, :limit, 100)
        )
      )

  def timeline(:runner, runner_id, opts) do
    limit = Keyword.get(opts, :limit, 100)

    Event
    |> where(
      [event],
      (event.entity_type == "runner" and event.entity_id == ^runner_id) or
        (event.entity_type == "runner_session" and event.owner == ^runner_id)
    )
    |> order_by([event], asc: event.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def timeline(:agent, agent_id, opts) do
    limit = Keyword.get(opts, :limit, 100)

    Event
    |> where(
      [event],
      (event.entity_type == "agent" and event.entity_id == ^agent_id) or
        (event.entity_type == "assignment" and event.owner == ^agent_id)
    )
    |> order_by([event], asc: event.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def timeline(scope, id, opts)
      when scope in [
             "workspace",
             "approval",
             "action",
             "assignment",
             "agent",
             "runner",
             "session"
           ],
      do: timeline(String.to_existing_atom(scope), id, opts)

  def record_workspace_snapshot(
        %WorkspaceSnapshot{} = snapshot,
        kind \\ "devide.snapshot.observed"
      ) do
    payload = decode_json(snapshot.snapshot, %{})

    record(%{
      source: "devide",
      kind: kind,
      entity_type: "workspace",
      entity_id: snapshot.workspace_id,
      workspace_id: snapshot.workspace_id,
      severity: workspace_severity(snapshot.status),
      summary: "DevIDE workspace #{snapshot.workspace_id} #{snapshot.status}",
      payload: %{
        workspace_id: snapshot.workspace_id,
        name: snapshot.name,
        status: snapshot.status,
        db_isolation: snapshot.db_isolation,
        attention_flags: decode_json(snapshot.attention_flags, []),
        last_observed_at: snapshot.last_observed_at,
        last_changed_at: snapshot.last_changed_at,
        snapshot: payload
      }
    })
  end

  def record_portfolio_risk(%WorkspaceSnapshot{} = snapshot, risk) do
    record(%{
      source: "devide",
      kind: "portfolio.risk.detected",
      entity_type: "portfolio_risk",
      entity_id: "#{snapshot.workspace_id}:#{risk}",
      workspace_id: snapshot.workspace_id,
      severity: workspace_severity(snapshot.status),
      summary: "DevIDE workspace #{snapshot.workspace_id} risk #{risk}",
      payload: %{
        workspace_id: snapshot.workspace_id,
        risk: risk,
        status: snapshot.status,
        db_isolation: snapshot.db_isolation,
        last_observed_at: snapshot.last_observed_at
      }
    })
  end

  def record_approval(%Approval{} = approval, kind, opts \\ []) do
    record(%{
      source: "approval",
      kind: kind,
      entity_type: "approval",
      entity_id: approval.approval_id,
      workspace_id: approval.workspace_id,
      approval_id: approval.approval_id,
      correlation_id: Keyword.get(opts, :correlation_id, correlation_id()),
      severity: approval.severity,
      summary: approval.summary,
      payload: %{
        approval_id: approval.approval_id,
        source: approval.source,
        workspace_id: approval.workspace_id,
        kind: approval.kind,
        severity: approval.severity,
        target_ref: approval.target_ref,
        status: approval.status,
        metadata: decode_json(approval.metadata, %{}),
        updated_at: approval.updated_at
      }
    })
  end

  def record_action(%OrchestrationAction{} = action, kind, opts \\ []) do
    payload = decode_json(action.payload, %{})
    correlation_id = text_field(payload, "correlation_id") || Keyword.get(opts, :correlation_id)
    extra_payload = Keyword.get(opts, :payload, %{})

    record(%{
      source: "safe_action",
      kind: kind,
      entity_type: "action",
      entity_id: action.action_id,
      workspace_id: text_field(payload, "workspace_id") || "",
      approval_id: action.ref,
      action_id: action.action_id,
      correlation_id: correlation_id || correlation_id(),
      severity: Keyword.get(opts, :severity, "info"),
      summary: Keyword.get(opts, :summary, action.result_summary),
      payload:
        Map.merge(
          %{
            action_id: action.action_id,
            action: action.action,
            status: action.status,
            outcome: action.outcome,
            ref: action.ref,
            target: action.target,
            result_summary: action.result_summary,
            payload: payload
          },
          extra_payload
        )
    })
  end

  def record_lease(%Lease{} = lease, kind, opts \\ []) do
    metadata = decode_json(lease.metadata, %{})

    record(%{
      source: "lease",
      kind: kind,
      entity_type: "lease",
      entity_id: lease.lease_id,
      workspace_id: text_field(metadata, "workspace_id") || "",
      lease_id: lease.lease_id,
      owner: lease.owner,
      correlation_id: lease.correlation_id,
      approval_id: if(lease.resource_type == "approval", do: lease.resource_id, else: ""),
      action_id: if(lease.resource_type == "action", do: lease.resource_id, else: ""),
      severity: Keyword.get(opts, :severity, "notice"),
      summary: "#{lease.resource_type} #{lease.resource_id} #{lease.status} by #{lease.owner}",
      payload: %{
        lease_id: lease.lease_id,
        resource_type: lease.resource_type,
        resource_id: lease.resource_id,
        owner: lease.owner,
        status: lease.status,
        reason: lease.reason,
        acquired_at: lease.acquired_at,
        expires_at: lease.expires_at,
        released_at: lease.released_at,
        reassigned_at: lease.reassigned_at,
        metadata: metadata
      }
    })
  end

  def correlation_id do
    random =
      8
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    @correlation_prefix <> random
  end

  def decode_payload(%Event{payload: payload}), do: decode_json(payload, %{})

  defp maybe_filter_kind(query, nil), do: query
  defp maybe_filter_kind(query, kind), do: where(query, [event], event.kind == ^kind)

  defp maybe_filter_entity(query, nil, _entity_id), do: query

  defp maybe_filter_entity(query, entity_type, nil),
    do: where(query, [event], event.entity_type == ^entity_type)

  defp maybe_filter_entity(query, entity_type, entity_id) do
    where(query, [event], event.entity_type == ^entity_type and event.entity_id == ^entity_id)
  end

  defp maybe_filter_workspace(query, nil), do: query

  defp maybe_filter_workspace(query, workspace_id),
    do: where(query, [event], event.workspace_id == ^workspace_id)

  defp maybe_filter_approval(query, nil), do: query

  defp maybe_filter_approval(query, approval_id),
    do: where(query, [event], event.approval_id == ^approval_id)

  defp maybe_filter_action(query, nil), do: query

  defp maybe_filter_action(query, action_id),
    do: where(query, [event], event.action_id == ^action_id)

  defp maybe_filter_lease(query, nil), do: query
  defp maybe_filter_lease(query, lease_id), do: where(query, [event], event.lease_id == ^lease_id)

  defp maybe_filter_correlation(query, nil), do: query

  defp maybe_filter_correlation(query, correlation_id),
    do: where(query, [event], event.correlation_id == ^correlation_id)

  defp workspace_severity("blocked"), do: "warning"
  defp workspace_severity("needs_review"), do: "warning"
  defp workspace_severity("unknown"), do: "notice"
  defp workspace_severity(_status), do: "info"

  defp encode_payload(payload) when is_binary(payload), do: payload
  defp encode_payload(payload), do: payload |> normalize_payload() |> Jason.encode!()

  defp normalize_payload(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_payload(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_payload(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_payload(%Time{} = value), do: Time.to_iso8601(value)

  defp normalize_payload(%{} = map) do
    Map.new(map, fn {key, value} -> {key, normalize_payload(value)} end)
  end

  defp normalize_payload(values) when is_list(values), do: Enum.map(values, &normalize_payload/1)
  defp normalize_payload(value), do: value

  defp decode_json(text, fallback) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> fallback
    end
  end

  defp decode_json(_text, fallback), do: fallback

  defp text_field(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when value in [nil, ""] -> nil
      value -> to_string(value)
    end
  end

  defp text_field(_map, _key), do: nil

  defp event_id do
    random =
      5
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    @event_prefix <> random
  end
end
