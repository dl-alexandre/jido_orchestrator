defmodule JX.Approvals.Evidence do
  @moduledoc """
  Builds self-contained, redacted evidence bundles for approval review.

  Evidence is read from JX state only. The latest stored DevIDE snapshot wins
  when present; approval metadata is used as a fallback for older items or
  missing snapshot rows.
  """

  alias JX.Approvals.Approval
  alias JX.DevIDE.WorkspaceSnapshot
  alias JX.Redaction
  alias JX.Repo

  @sensitive_key ~r/(token|secret|password|passwd|api[_-]?key|access[_-]?key|private[_-]?key|credential|authorization|auth)/i

  @spec build(Approval.t()) :: map()
  def build(%Approval{} = approval) do
    metadata = decode_json(approval.metadata, %{}) |> redact()
    stored = stored_snapshot(approval.workspace_id)
    stored_snapshot = stored && decode_json(stored.snapshot, %{})
    metadata_evidence = field(metadata, "evidence") || %{}
    metadata_snapshot = field(metadata_evidence, "snapshot") || %{}
    snapshot = first_map([stored_snapshot, metadata_snapshot])
    source = evidence_source(stored, metadata_snapshot, snapshot)
    missing = missing_fields(stored, metadata_snapshot, snapshot)

    %{
      source: source,
      approval: approval_summary(approval),
      workspace: workspace_summary(approval, stored, snapshot),
      reason: reason_summary(approval, metadata),
      related: related_refs(approval, metadata),
      latest_runs: list_value(field(snapshot, "latest_runs")),
      active_run: map_value(field(snapshot, "active_run")),
      proposal_risks: list_value(field(snapshot, "proposal_risks")),
      policy: policy_summary(snapshot),
      metadata: metadata,
      missing: missing
    }
    |> redact()
  end

  defp stored_snapshot(""), do: nil
  defp stored_snapshot(nil), do: nil

  defp stored_snapshot(workspace_id),
    do: Repo.get_by(WorkspaceSnapshot, workspace_id: workspace_id)

  defp approval_summary(%Approval{} = approval) do
    %{
      approval_id: approval.approval_id,
      status: approval.status,
      source: approval.source,
      workspace_id: approval.workspace_id,
      kind: approval.kind,
      severity: approval.severity,
      target_ref: approval.target_ref,
      summary: approval.summary,
      inserted_at: approval.inserted_at,
      updated_at: approval.updated_at,
      acknowledged_at: approval.acknowledged_at,
      dismissed_at: approval.dismissed_at
    }
  end

  defp workspace_summary(%Approval{}, %WorkspaceSnapshot{} = stored, snapshot) do
    %{
      id: stored.workspace_id,
      name: first_present([stored.name, field(snapshot, "name")]),
      status: first_present([stored.status, field(snapshot, "status")]),
      lifecycle_status:
        first_present([stored.lifecycle_status, field(snapshot, "lifecycle_status")]),
      mode: first_present([stored.mode, field(snapshot, "mode")]),
      db_isolation: first_present([stored.db_isolation, field(snapshot, "db_isolation")]),
      attention_flags:
        decode_json(stored.attention_flags, list_value(field(snapshot, "attention_flags"))),
      source_url: stored.source_url,
      last_observed_at: stored.last_observed_at,
      last_changed_at: stored.last_changed_at
    }
  end

  defp workspace_summary(%Approval{} = approval, _stored, snapshot) do
    %{
      id: first_present([approval.workspace_id, field(snapshot, "id")]),
      name: field(snapshot, "name") || "",
      status: field(snapshot, "status") || "",
      lifecycle_status: field(snapshot, "lifecycle_status") || "",
      mode: field(snapshot, "mode") || "",
      db_isolation: field(snapshot, "db_isolation") || "",
      attention_flags: list_value(field(snapshot, "attention_flags")),
      source_url: "",
      last_observed_at: nil,
      last_changed_at: nil
    }
  end

  defp reason_summary(%Approval{} = approval, metadata) do
    %{
      kind: approval.kind,
      severity: approval.severity,
      target_ref: approval.target_ref,
      summary: approval.summary,
      transition: field(metadata, "transition") || %{}
    }
  end

  defp related_refs(%Approval{kind: "proposal_conflict"} = approval, metadata) do
    proposal = field(metadata, "proposal") || %{}

    %{
      proposal: proposal,
      proposal_path: first_present([field(proposal, "path"), approval.target_ref]),
      proposal_risk: field(proposal, "risk") || field(metadata, "risk") || "",
      notification_id: field(metadata, "notification_id") || "",
      source_event_id: field(metadata, "source_event_id") || ""
    }
  end

  defp related_refs(%Approval{kind: "failed_run"} = approval, metadata) do
    run = field(metadata, "run") || %{}

    %{
      run: run,
      run_id: field(run, "id") || "",
      command_id: first_present([field(run, "command_id"), approval.target_ref]),
      run_status: field(run, "status") || "",
      notification_id: field(metadata, "notification_id") || "",
      source_event_id: field(metadata, "source_event_id") || ""
    }
  end

  defp related_refs(%Approval{kind: "policy_blocked"} = approval, metadata) do
    block = field(metadata, "block") || %{}

    %{
      audit: block,
      audit_action: field(block, "action") || "policy.blocked",
      target_ref: approval.target_ref,
      notification_id: field(metadata, "notification_id") || "",
      source_event_id: field(metadata, "source_event_id") || ""
    }
  end

  defp related_refs(%Approval{kind: "unsafe_db"} = approval, metadata) do
    %{
      db_isolation: first_present([field(metadata, "db_isolation"), approval.target_ref]),
      notification_id: field(metadata, "notification_id") || "",
      source_event_id: field(metadata, "source_event_id") || ""
    }
  end

  defp related_refs(_approval, metadata) do
    %{
      notification_id: field(metadata, "notification_id") || "",
      source_event_id: field(metadata, "source_event_id") || ""
    }
  end

  defp policy_summary(snapshot) do
    %{
      mode: field(snapshot, "mode") || "",
      db_isolation: field(snapshot, "db_isolation") || "",
      recent_blocks: list_value(field(snapshot, "recent_blocks")),
      attention_flags: list_value(field(snapshot, "attention_flags"))
    }
  end

  defp evidence_source(%WorkspaceSnapshot{}, _metadata_snapshot, _snapshot),
    do: "stored_devide_snapshot"

  defp evidence_source(_stored, metadata_snapshot, snapshot)
       when metadata_snapshot == snapshot and snapshot != %{},
       do: "approval_metadata"

  defp evidence_source(_stored, _metadata_snapshot, snapshot) when snapshot == %{}, do: "missing"
  defp evidence_source(_stored, _metadata_snapshot, _snapshot), do: "derived"

  defp missing_fields(%WorkspaceSnapshot{}, _metadata_snapshot, _snapshot), do: []

  defp missing_fields(_stored, metadata_snapshot, snapshot) do
    []
    |> maybe_missing(true, "stored_workspace_snapshot")
    |> maybe_missing(snapshot == %{}, "workspace_snapshot")
    |> maybe_missing(metadata_snapshot == %{}, "captured_evidence")
    |> Enum.reverse()
  end

  defp maybe_missing(fields, true, field), do: [field | fields]
  defp maybe_missing(fields, false, _field), do: fields

  defp first_map(values) do
    Enum.find(values, %{}, fn value -> is_map(value) and map_size(value) > 0 end)
  end

  defp decode_json(text, fallback) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> fallback
    end
  end

  defp decode_json(_text, fallback), do: fallback

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp field(_value, _key), do: nil

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp map_value(value) when is_map(value), do: value
  defp map_value(_value), do: nil

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

  defp redact(%DateTime{} = value), do: value
  defp redact(%NaiveDateTime{} = value), do: value
  defp redact(%Date{} = value), do: value
  defp redact(%Time{} = value), do: value

  defp redact(%{} = map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key), do: {key, "<redacted>"}, else: {key, redact(value)}
    end)
  end

  defp redact(values) when is_list(values), do: Enum.map(values, &redact/1)
  defp redact(value) when is_binary(value), do: Redaction.redact_command(value)
  defp redact(value), do: value

  defp sensitive_key?(key), do: Regex.match?(@sensitive_key, to_string(key))
end
