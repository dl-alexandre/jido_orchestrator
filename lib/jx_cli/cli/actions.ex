defmodule JX.CLI.Actions do
  @moduledoc false

  alias JX.OrchestrationActions
  alias JX.SafeActions.Action, as: SafeAction
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @actions_ls_usage "jx actions ls [--source <source>] [--ref <ref>] [--action <action>] [--status planned|queued|executed|skipped|error|cancelled] [--outcome helpful|ignored|blocked|superseded|failed] [-n 50] [--json]"
  @actions_show_usage "jx actions show <action-id> [--json]"
  @actions_history_usage "jx actions history <approval-id> [--json]"
  @actions_propose_usage "jx actions propose <approval-id> [--kind rerun_devide_command|acknowledge_approval] [--owner <owner>] [--json]"
  @actions_dry_run_usage "jx actions dry-run <action-id> [--owner <owner>] [--json]"
  @actions_execute_usage "jx actions execute <action-id> --confirm [--owner <owner>] [--json]"

  def usage_lines do
    [
      @actions_ls_usage,
      @actions_show_usage,
      @actions_history_usage,
      @actions_propose_usage,
      @actions_dry_run_usage,
      @actions_execute_usage,
      "",
      "`actions show` prints retry/reproposal guidance. Retry only planned actions after network or resolved DevIDE failures. Repropose after policy denials, stale evidence, expired/revoked actions, or approval mismatch."
    ]
  end

  def usage do
    [
      @actions_ls_usage,
      @actions_show_usage,
      @actions_history_usage,
      @actions_propose_usage,
      @actions_dry_run_usage,
      @actions_execute_usage
    ]
    |> Enum.join(" | ")
  end

  def run(["ls" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          ref: :string,
          action: :string,
          source: :string,
          status: :string,
          outcome: :string,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @actions_ls_usage),
         :ok <- validate_optional_action_status(parsed[:status]),
         :ok <- validate_optional_action_outcome(parsed[:outcome]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:list_orchestration_actions, [
        [
          source: parsed[:source],
          ref: parsed[:ref],
          action: parsed[:action],
          status: parsed[:status],
          outcome: parsed[:outcome],
          limit: limit
        ]
      ])
      |> print_orchestration_actions(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["show", action_id | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @actions_show_usage),
         :ok <- start_app(opts),
         {:ok, result} <- apply(workspace(opts), :show_action, [action_id]) do
      print_safe_action_show(result, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["history", approval_id | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @actions_history_usage),
         :ok <- start_app(opts),
         {:ok, result} <- apply(workspace(opts), :action_history, [approval_id]) do
      print_safe_action_history(result, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["propose", approval_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [kind: :string, action: :string, owner: :string, json: :boolean]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @actions_propose_usage),
         {:ok, kind} <- safe_action_kind(parsed),
         :ok <- start_app(opts),
         {:ok, result} <-
           apply(workspace(opts), :propose_action, [
             approval_id,
             [kind: kind, owner: parsed[:owner]]
           ]) do
      print_safe_action_result("proposed", result, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["dry-run", action_id | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [owner: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @actions_dry_run_usage),
         :ok <- start_app(opts),
         {:ok, result} <-
           apply(workspace(opts), :dry_run_action, [action_id, [owner: parsed[:owner]]]) do
      print_safe_action_result("dry run", result, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["execute", action_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [confirm: :boolean, owner: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @actions_execute_usage),
         :ok <- start_app(opts) do
      if parsed[:confirm] do
        with {:ok, result} <-
               apply(workspace(opts), :execute_action, [
                 action_id,
                 [confirm: true, owner: parsed[:owner]]
               ]) do
          print_safe_action_result("executed", result, json: parsed[:json] || false)
          :ok
        end
      else
        with {:ok, result} <-
               apply(workspace(opts), :dry_run_action, [action_id, [owner: parsed[:owner]]]) do
          print_safe_action_result("dry run", result, json: parsed[:json] || false)
          _ = apply(workspace(opts), :execute_action, [action_id, [confirm: false]])
          {:error, "confirmation required; pass --confirm to execute this action"}
        end
      end
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

  defp validate_optional_action_status(nil), do: :ok

  defp validate_optional_action_status(status) do
    statuses = OrchestrationActions.statuses()

    if status in statuses do
      :ok
    else
      {:error,
       "unsupported action status #{inspect(status)}; expected one of: #{Enum.join(statuses, ", ")}"}
    end
  end

  defp validate_optional_action_outcome(nil), do: :ok

  defp validate_optional_action_outcome(outcome) do
    outcomes = OrchestrationActions.outcomes()

    if outcome in outcomes do
      :ok
    else
      {:error,
       "unsupported action outcome #{inspect(outcome)}; expected one of: #{Enum.join(outcomes, ", ")}"}
    end
  end

  defp safe_action_kind(opts) do
    kind = opts[:kind]
    action = opts[:action]

    cond do
      text_present?(kind) and text_present?(action) and kind != action ->
        {:error, "--kind and --action must match when both are provided"}

      text_present?(kind) ->
        validate_safe_action_kind(kind)

      text_present?(action) ->
        validate_safe_action_kind(action)

      true ->
        {:ok, "rerun_devide_command"}
    end
  end

  defp validate_safe_action_kind(kind) do
    kinds = SafeAction.kinds()

    if kind in kinds do
      {:ok, kind}
    else
      {:error,
       "unsupported safe action #{inspect(kind)}; expected one of: #{Enum.join(kinds, ", ")}"}
    end
  end

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp print_orchestration_actions([], opts) do
    if opts[:json] do
      print_json(%{actions: []})
    else
      IO.puts("no orchestration actions")
    end
  end

  defp print_orchestration_actions(actions, opts) do
    if opts[:json] do
      print_json(%{actions: Enum.map(actions, &json_orchestration_action/1)})
    else
      rows =
        Enum.map(actions, fn action ->
          [
            action.action_id,
            action.status,
            action.source,
            action.action,
            action.safety,
            action.ref,
            action.outcome,
            truncate(action.reason, 48),
            truncate(action.result_summary, 72),
            format_time(action.updated_at)
          ]
        end)

      print_table(
        [
          "ACTION_ID",
          "STATUS",
          "SOURCE",
          "ACTION",
          "SAFETY",
          "REF",
          "OUTCOME",
          "REASON",
          "RESULT",
          "AT"
        ],
        rows
      )
    end
  end

  defp print_safe_action_result(label, result, opts) do
    if opts[:json] do
      print_json(json_safe_action_result(result))
    else
      action = result.action
      safe_action = result.safe_action

      IO.puts("#{label} #{action.action_id}")
      IO.puts("kind: #{safe_action.kind}")
      IO.puts("approval: #{safe_action.approval_id}")
      IO.puts("workspace: #{safe_action.workspace_id}")
      print_safe_action_field("command", safe_action.command_id)
      print_safe_action_field("db_isolation", safe_action.db_isolation)
      IO.puts("would do: #{result.would_do}")
      print_safe_action_execution(result)
      print_safe_action_result_next(label, result)
    end
  end

  defp print_safe_action_result_next("proposed", %{action: action, safe_action: safe_action}) do
    IO.puts("next: jx actions dry-run #{action.action_id}")
    IO.puts("execute: jx actions execute #{action.action_id} --confirm")
    IO.puts("audit: jx actions history #{safe_action.approval_id}")
  end

  defp print_safe_action_result_next("dry run", %{action: action, safe_action: safe_action}) do
    IO.puts("next: jx actions execute #{action.action_id} --confirm")
    IO.puts("audit: jx actions history #{safe_action.approval_id}")
  end

  defp print_safe_action_result_next("executed", %{action: action, safe_action: safe_action}) do
    IO.puts("next: jx actions show #{action.action_id}")
    IO.puts("audit: jx actions history #{safe_action.approval_id}")
  end

  defp print_safe_action_result_next(_label, _result), do: :ok

  defp print_safe_action_field(_label, value) when value in [nil, ""], do: :ok
  defp print_safe_action_field(label, value), do: IO.puts("#{label}: #{value}")

  defp print_safe_action_execution(%{executed: true, run: run}) when is_map(run) do
    IO.puts("execution: executed")
    IO.puts("run: #{Map.get(run, "id") || Map.get(run, :id) || "-"}")
    IO.puts("status: #{Map.get(run, "status") || Map.get(run, :status) || "-"}")
  end

  defp print_safe_action_execution(%{executed: true, approval: approval}) do
    IO.puts("execution: executed")
    IO.puts("approval_status: #{approval.status}")
  end

  defp print_safe_action_execution(_result) do
    IO.puts("execution: requires --confirm")
  end

  defp print_safe_action_show(%{action: action, payload: payload, events: events} = result, opts) do
    if opts[:json] do
      print_json(%{
        action: json_orchestration_action(action),
        payload: payload,
        events: Enum.map(events, &json_safe_action_event/1),
        guidance: Map.get(result, :guidance)
      })
    else
      IO.puts("action #{action.action_id}")
      IO.puts("kind: #{action.action}")
      IO.puts("status: #{action.status}")
      IO.puts("outcome: #{blank_to_dash(action.outcome)}")
      IO.puts("correlation_id: #{safe_action_correlation_id(action, payload, events)}")
      IO.puts("approval: #{action.ref}")
      IO.puts("approval_detail: jx approvals show #{action.ref}")
      IO.puts("devide_status: #{safe_action_devide_status(payload)}")
      IO.puts("side_effect_target: #{blank_to_dash(action.target)}")
      IO.puts("evidence: #{safe_action_evidence(payload)}")
      IO.puts("policy_denial: #{safe_action_policy_denial(events)}")
      IO.puts("result: #{blank_to_dash(action.result_summary)}")
      IO.puts("next: #{blank_to_dash(Map.get(result, :guidance))}")
      print_safe_action_events(events)
    end
  end

  defp print_safe_action_history(%{approval_id: approval_id, events: events} = result, opts) do
    if opts[:json] do
      print_json(%{
        approval_id: approval_id,
        actions: Enum.map(Map.get(result, :actions, []), &json_orchestration_action/1),
        events: Enum.map(events, &json_safe_action_event/1),
        guidance: Map.get(result, :guidance, %{})
      })
    else
      IO.puts("action history #{approval_id}")
      IO.puts("approval_detail: jx approvals show #{approval_id}")

      print_safe_action_history_actions(
        Map.get(result, :actions, []),
        Map.get(result, :guidance, %{}),
        events
      )

      print_safe_action_events(events)
    end
  end

  defp print_safe_action_history_actions([], _guidance, _events), do: IO.puts("actions: none")

  defp print_safe_action_history_actions(actions, guidance, events) do
    IO.puts("actions")

    Enum.each(actions, fn action ->
      payload = operation_execution_snapshot(action.payload)
      action_events = Enum.filter(events, &(&1.action_id == action.action_id))

      IO.puts(
        "  - id=#{action.action_id} kind=#{action.action} status=#{action.status} outcome=#{blank_to_dash(action.outcome)} correlation_id=#{safe_action_correlation_id(action, payload, action_events)} target=#{blank_to_dash(action.target)} policy_denial=#{safe_action_policy_denial(action_events)}"
      )

      IO.puts("    evidence: #{safe_action_evidence(payload)}")
      IO.puts("    next: #{blank_to_dash(Map.get(guidance, action.action_id))}")
    end)
  end

  defp print_safe_action_events([]), do: IO.puts("events: none")

  defp print_safe_action_events(events) do
    IO.puts("events")

    Enum.each(events, fn event ->
      payload = operation_execution_snapshot(event.payload)
      target = payload |> safe_action_payload_field("target") |> blank_to_dash()
      reason = blank_to_dash(event.reason)

      IO.puts(
        "  - action=#{event.action_id} kind=#{event.kind} outcome=#{event.outcome} correlation_id=#{event.correlation_id} target=#{target} reason=#{reason}"
      )
    end)
  end

  defp json_safe_action_result(result) do
    %{
      action: json_orchestration_action(result.action),
      safe_action: result.safe_action,
      would_do: result.would_do,
      dry_run_only: result.dry_run_only,
      executed: result.executed,
      mode: result.mode,
      run: Map.get(result, :run),
      devide_response: Map.get(result, :devide_response)
    }
  end

  defp json_orchestration_action(action) do
    %{
      action_id: action.action_id,
      queue_key: action.queue_key,
      requested: action.requested,
      source: action.source,
      recommendation_id: action.recommendation_id,
      action: action.action,
      safety: action.safety,
      ref: action.ref,
      target: action.target,
      status: action.status,
      reason: action.reason,
      error: action.error,
      result_summary: action.result_summary,
      outcome: action.outcome,
      outcome_reason: action.outcome_reason,
      payload: operation_execution_snapshot(action.payload),
      scheduled_at: format_time(action.scheduled_at),
      executed_at: format_time(action.executed_at),
      completed_at: format_time(action.completed_at),
      inserted_at: format_time(action.inserted_at),
      updated_at: format_time(action.updated_at)
    }
  end

  defp json_safe_action_event(event) do
    %{
      event_id: event.event_id,
      correlation_id: event.correlation_id,
      action_id: event.action_id,
      approval_id: event.approval_id,
      workspace_id: event.workspace_id,
      command_id: event.command_id,
      kind: event.kind,
      outcome: event.outcome,
      reason: event.reason,
      payload: operation_execution_snapshot(event.payload),
      inserted_at: format_time(event.inserted_at)
    }
  end

  defp safe_action_correlation_id(action, payload, events) do
    safe_action_first_present([
      safe_action_payload_field(payload, "correlation_id"),
      Enum.find_value(events, &text_present_or_nil(&1.correlation_id)),
      action.action_id
    ])
  end

  defp safe_action_evidence(payload) do
    [
      {"approval", safe_action_payload_field(payload, "approval_id")},
      {"workspace", safe_action_payload_field(payload, "workspace_id")},
      {"command", safe_action_payload_field(payload, "command_id")},
      {"db_isolation", safe_action_payload_field(payload, "db_isolation")},
      {"target_ref", safe_action_payload_field(payload, "target_ref")}
    ]
    |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
    |> Enum.map_join(" ", fn {label, value} -> "#{label}=#{value}" end)
    |> blank_to_dash()
  end

  defp safe_action_policy_denial(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn event ->
      if event.kind == "execute_denied" and event.outcome == "policy_denied" do
        event.reason
      end
    end)
    |> blank_to_dash()
  end

  defp safe_action_devide_status(payload) do
    case safe_action_payload_field(payload, "workspace_id") |> text_present_or_nil() do
      nil -> "-"
      workspace_id -> "jx devide status #{workspace_id}"
    end
  end

  defp safe_action_payload_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp safe_action_payload_field(_value, _key), do: nil

  defp safe_action_first_present(values) do
    Enum.find_value(values, "-", &text_present_or_nil/1)
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

  defp text_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp text_present?(_value), do: false

  defp text_present_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp text_present_or_nil(nil), do: nil
  defp text_present_or_nil(value), do: to_string(value)

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

  defp blank_to_dash(value) when value in [nil, ""], do: "-"
  defp blank_to_dash(value), do: to_string(value)
end
