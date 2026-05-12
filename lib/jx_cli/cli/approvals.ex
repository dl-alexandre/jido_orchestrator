defmodule JX.CLI.Approvals do
  @moduledoc false

  alias JX.Approvals
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @approvals_ls_usage "jx approvals ls [--status open|acknowledged|dismissed|active|all] [--source devide] [--workspace <id>] [--kind <kind>] [-n 50] [--json]"
  @approvals_show_usage "jx approvals show <id> [--json]"
  @approvals_ack_usage "jx approvals ack <id> [--json]"
  @approvals_dismiss_usage "jx approvals dismiss <id> [--json]"

  def usage_lines do
    [
      "jx approvals ls [--status open|acknowledged|dismissed|active|all] [--source devide] [--workspace <id>] [--kind proposal_conflict|unsafe_db|failed_run|policy_blocked] [-n 50] [--json]",
      @approvals_show_usage,
      @approvals_ack_usage,
      @approvals_dismiss_usage
    ]
  end

  def usage do
    Enum.join(usage_lines(), " | ")
  end

  def run(["ls" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          status: :string,
          source: :string,
          workspace: :string,
          kind: :string,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @approvals_ls_usage),
         :ok <- validate_optional_approval_status(parsed[:status]),
         :ok <- validate_optional_approval_source(parsed[:source]),
         :ok <- validate_optional_approval_kind(parsed[:kind]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:list_approvals, [
        [
          status: parsed[:status],
          source: parsed[:source],
          workspace_id: parsed[:workspace],
          kind: parsed[:kind],
          limit: limit
        ]
      ])
      |> print_approvals(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["show", approval_id | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @approvals_show_usage),
         :ok <- start_app(opts),
         {:ok, detail} <- apply(workspace(opts), :approval_detail, [approval_id]) do
      print_approval_detail(detail, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["ack", approval_id | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @approvals_ack_usage),
         :ok <- start_app(opts),
         {:ok, approval} <- apply(workspace(opts), :acknowledge_approval, [approval_id]) do
      print_approval_status("acknowledged", approval, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["dismiss", approval_id | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @approvals_dismiss_usage),
         :ok <- start_app(opts),
         {:ok, approval} <- apply(workspace(opts), :dismiss_approval, [approval_id]) do
      print_approval_status("dismissed", approval, json: parsed[:json] || false)
      :ok
    end
  end

  def run(_args, _opts), do: {:error, "usage: #{usage()}"}

  defp workspace(opts), do: Keyword.get(opts, :workspace, Workspace)

  defp start_app(opts) do
    case Keyword.fetch(opts, :start_app) do
      {:ok, start_app} -> start_app.()
      :error -> {:error, :missing_start_app_callback}
    end
  end

  defp validate_optional_approval_status(nil), do: :ok
  defp validate_optional_approval_status("active"), do: :ok
  defp validate_optional_approval_status("all"), do: :ok

  defp validate_optional_approval_status(status) do
    statuses = Approvals.statuses()

    if status in statuses do
      :ok
    else
      {:error,
       "unsupported approval status #{inspect(status)}; expected one of: #{Enum.join(statuses ++ ["active", "all"], ", ")}"}
    end
  end

  defp validate_optional_approval_source(nil), do: :ok

  defp validate_optional_approval_source(source) do
    sources = Approvals.sources()

    if source in sources do
      :ok
    else
      {:error,
       "unsupported approval source #{inspect(source)}; expected one of: #{Enum.join(sources, ", ")}"}
    end
  end

  defp validate_optional_approval_kind(nil), do: :ok

  defp validate_optional_approval_kind(kind) do
    kinds = Approvals.kinds()

    if kind in kinds do
      :ok
    else
      {:error,
       "unsupported approval kind #{inspect(kind)}; expected one of: #{Enum.join(kinds, ", ")}"}
    end
  end

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp print_approvals([], opts) do
    if opts[:json] do
      print_json(%{approvals: []})
    else
      IO.puts("no approvals")
    end
  end

  defp print_approvals(approvals, opts) do
    if opts[:json] do
      print_json(%{approvals: Enum.map(approvals, &json_approval/1)})
    else
      rows =
        Enum.map(approvals, fn approval ->
          [
            approval.approval_id,
            approval.status,
            approval.severity,
            approval.source,
            approval.workspace_id,
            approval.kind,
            truncate(approval.target_ref, 40),
            truncate(approval.summary, 96),
            format_time(approval.updated_at)
          ]
        end)

      print_table(
        ["ID", "STATUS", "SEVERITY", "SOURCE", "WORKSPACE", "KIND", "TARGET", "SUMMARY", "AT"],
        rows
      )

      IO.puts("")
      IO.puts("next: jx approvals show <id>")
      IO.puts("claim: jx leases acquire approval <id> --owner <owner>")

      IO.puts(
        "safe action: jx actions propose <id> [--owner <owner>] [--kind acknowledge_approval]"
      )
    end
  end

  defp print_approval_detail(
         %{approval: approval, evidence: evidence, recommendation: recommendation},
         opts
       ) do
    if opts[:json] do
      print_json(
        json_approval_detail(%{
          approval: approval,
          evidence: evidence,
          recommendation: recommendation
        })
      )
    else
      IO.puts("approval #{approval.approval_id}")
      IO.puts("")
      print_approval_evidence_freshness(evidence)
      IO.puts("")
      print_approval_workspace(evidence.workspace)
      IO.puts("")
      print_approval_reason(evidence.reason)
      IO.puts("")
      print_approval_related(evidence.related)
      IO.puts("")
      print_approval_runs(evidence)
      IO.puts("")
      print_approval_proposals(evidence.proposal_risks)
      IO.puts("")
      print_approval_policy(evidence.policy)
      IO.puts("")
      print_approval_recommendation(recommendation)
      print_approval_safe_action_workflow(approval)
      print_approval_missing(evidence.missing)
    end
  end

  defp print_approval_evidence_freshness(evidence) do
    workspace = Map.get(evidence, :workspace, %{})
    missing = Map.get(evidence, :missing, [])

    missing_text =
      case missing do
        [] -> "none"
        values -> Enum.join(values, ",")
      end

    IO.puts("evidence freshness")
    IO.puts("  source: #{Map.get(evidence, :source, "")}")
    IO.puts("  last_observed_at: #{format_time(Map.get(workspace, :last_observed_at))}")
    IO.puts("  last_changed_at: #{format_time(Map.get(workspace, :last_changed_at))}")
    IO.puts("  missing: #{missing_text}")
  end

  defp print_approval_workspace(workspace) do
    IO.puts("workspace summary")
    IO.puts("  id: #{Map.get(workspace, :id, "")}")
    IO.puts("  name: #{Map.get(workspace, :name, "")}")
    IO.puts("  status: #{Map.get(workspace, :status, "")}")
    IO.puts("  lifecycle_status: #{Map.get(workspace, :lifecycle_status, "")}")
    IO.puts("  mode: #{Map.get(workspace, :mode, "")}")
    IO.puts("  db_isolation: #{Map.get(workspace, :db_isolation, "")}")
    IO.puts("  last_observed_at: #{format_time(Map.get(workspace, :last_observed_at))}")
  end

  defp print_approval_reason(reason) do
    IO.puts("reason/severity")
    IO.puts("  kind: #{Map.get(reason, :kind, "")}")
    IO.puts("  severity: #{Map.get(reason, :severity, "")}")
    IO.puts("  target_ref: #{Map.get(reason, :target_ref, "")}")
    IO.puts("  summary: #{Map.get(reason, :summary, "")}")
  end

  defp print_approval_related(related) do
    IO.puts("related DevIDE refs")

    related
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}, []] end)
    |> Enum.each(fn {key, value} ->
      IO.puts("  #{key}: #{approval_value(value)}")
    end)
  end

  defp print_approval_runs(evidence) do
    IO.puts("latest command runs")

    rows =
      evidence
      |> Map.get(:latest_runs, [])
      |> Enum.take(10)
      |> Enum.map(&approval_run_row/1)

    rows =
      case Map.get(evidence, :active_run) do
        nil ->
          rows

        run ->
          [
            [
              "active",
              run |> Map.get("command_id", "") |> to_string(),
              run |> Map.get("status", "") |> to_string(),
              run |> Map.get("exit_code", "") |> to_string(),
              run |> Map.get("finished_at", "") |> to_string()
            ]
            | rows
          ]
      end

    if rows == [] do
      IO.puts("  none")
    else
      print_table(["SCOPE", "COMMAND", "STATUS", "EXIT", "FINISHED"], rows)
    end
  end

  defp approval_run_row(run) when is_map(run) do
    [
      "latest",
      run |> Map.get("command_id", "") |> to_string(),
      run |> Map.get("status", "") |> to_string(),
      run |> Map.get("exit_code", "") |> to_string(),
      run |> Map.get("finished_at", "") |> to_string()
    ]
  end

  defp print_approval_proposals([]) do
    IO.puts("proposal risk summary")
    IO.puts("  none")
  end

  defp print_approval_proposals(proposals) do
    IO.puts("proposal risk summary")

    rows =
      Enum.map(proposals, fn proposal ->
        [
          proposal |> Map.get("path", "") |> to_string(),
          proposal |> Map.get("risk", "") |> to_string(),
          proposal |> Map.get("files_count", "") |> to_string(),
          proposal |> Map.get("overlapping_files", []) |> approval_value()
        ]
      end)

    print_table(["PATH", "RISK", "FILES", "OVERLAPS"], rows)
  end

  defp print_approval_policy(policy) do
    IO.puts("db isolation/policy mode")
    IO.puts("  mode: #{Map.get(policy, :mode, "")}")
    IO.puts("  db_isolation: #{Map.get(policy, :db_isolation, "")}")
    IO.puts("  attention_flags: #{policy |> Map.get(:attention_flags, []) |> approval_value()}")

    blocks = Map.get(policy, :recent_blocks, [])

    if blocks == [] do
      IO.puts("  recent_blocks: none")
    else
      rows =
        Enum.map(blocks, fn block ->
          [
            block |> Map.get("action", "") |> to_string(),
            [Map.get(block, "target_type"), Map.get(block, "target_ref")]
            |> Enum.reject(&(&1 in [nil, ""]))
            |> Enum.join(":"),
            block |> Map.get("reason", "") |> to_string(),
            block |> Map.get("inserted_at", "") |> to_string()
          ]
        end)

      print_table(["ACTION", "TARGET", "REASON", "AT"], rows)
    end
  end

  defp print_approval_recommendation(recommendation) do
    IO.puts("suggested next safe action")
    IO.puts("  #{Map.get(recommendation, :primary, "")}")

    recommendation
    |> Map.get(:actions, [])
    |> Enum.drop(1)
    |> Enum.each(&IO.puts("  - #{&1}"))
  end

  defp print_approval_safe_action_workflow(approval) do
    IO.puts("")
    IO.puts("safe-action workflow")
    IO.puts("  claim: jx leases acquire approval #{approval.approval_id} --owner <owner>")

    if approval.kind == "failed_run" do
      IO.puts("  propose rerun: jx actions propose #{approval.approval_id} --owner <owner>")
    end

    IO.puts(
      "  propose acknowledgment: jx actions propose #{approval.approval_id} --owner <owner> --kind acknowledge_approval"
    )

    IO.puts("  dry-run: jx actions dry-run <action-id> --owner <owner>")
    IO.puts("  execute: jx actions execute <action-id> --confirm --owner <owner>")
    IO.puts("  audit: jx actions history #{approval.approval_id}")
  end

  defp print_approval_missing([]), do: :ok

  defp print_approval_missing(missing) do
    IO.puts("")
    IO.puts("missing evidence")
    Enum.each(missing, &IO.puts("  - #{&1}"))
  end

  defp approval_value(values) when is_list(values),
    do: Enum.map_join(values, ",", &approval_value/1)

  defp approval_value(%{} = map), do: Jason.encode!(map)
  defp approval_value(nil), do: ""
  defp approval_value(value), do: to_string(value)

  defp print_approval_status(action, approval, opts) do
    if opts[:json] do
      print_json(json_approval(approval))
    else
      IO.puts("#{action} #{approval.approval_id}")
    end
  end

  defp json_approval(approval) do
    %{
      approval_id: approval.approval_id,
      source: approval.source,
      workspace_id: approval.workspace_id,
      kind: approval.kind,
      severity: approval.severity,
      target_ref: approval.target_ref,
      summary: approval.summary,
      status: approval.status,
      metadata: operation_execution_snapshot(approval.metadata),
      acknowledged_at: format_time(approval.acknowledged_at),
      dismissed_at: format_time(approval.dismissed_at),
      inserted_at: format_time(approval.inserted_at),
      updated_at: format_time(approval.updated_at)
    }
  end

  defp json_approval_detail(%{
         approval: approval,
         evidence: evidence,
         recommendation: recommendation
       }) do
    approval
    |> json_approval()
    |> Map.put(:evidence, json_approval_evidence(evidence))
    |> Map.put(:recommendation, recommendation)
  end

  defp json_approval_evidence(evidence) do
    evidence
    |> Map.update(:approval, %{}, fn approval ->
      approval
      |> Map.update(:inserted_at, nil, &format_time/1)
      |> Map.update(:updated_at, nil, &format_time/1)
      |> Map.update(:acknowledged_at, nil, &format_time/1)
      |> Map.update(:dismissed_at, nil, &format_time/1)
    end)
    |> update_in([:workspace], fn
      nil ->
        nil

      workspace ->
        workspace
        |> Map.update(:last_observed_at, nil, &format_time/1)
        |> Map.update(:last_changed_at, nil, &format_time/1)
    end)
  end

  defp operation_execution_snapshot(snapshot) do
    snapshot
    |> observation_snapshot()
    |> redact_operation_snapshot()
  end

  defp observation_snapshot(snapshot) when is_binary(snapshot) do
    case Jason.decode(snapshot) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> snapshot
    end
  end

  defp observation_snapshot(snapshot), do: snapshot

  defp redact_operation_snapshot(%{"capture" => %{"output" => output} = capture} = snapshot)
       when is_binary(output) do
    capture =
      capture
      |> Map.delete("output")
      |> Map.put("output_redacted", true)
      |> Map.put("output_bytes", byte_size(output))

    Map.put(snapshot, "capture", capture)
  end

  defp redact_operation_snapshot(snapshot), do: snapshot

  defp truncate(value, max_length) do
    value = value || ""

    if String.length(value) > max_length do
      String.slice(value, 0, max_length - 3) <> "..."
    else
      value
    end
  end

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value) when is_binary(value), do: if(value == "", do: "-", else: value)
end
