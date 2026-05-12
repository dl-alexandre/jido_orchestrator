defmodule JX.CLI.Assignments do
  @moduledoc false

  alias JX.DelegatedExecution.{Assignment, RunnerSession}
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @assignments_create_usage "jx assignments create <action-id> [--created-by <operator>] [--ttl-seconds 1800] [--json]"
  @assignments_ls_usage "jx assignments ls [--status created|claimed|started|progressed|completed|failed|expired|active|all] [--agent <id>] [--workspace <id>] [-n 50] [--json]"
  @assignments_claim_usage "jx assignments claim <assignment-id> (--agent <agent-id>|--runner <runner-id>) [--session <id>] [--tmux-session <name>] [--log-path <path>] [--json]"
  @assignments_start_usage "jx assignments start <assignment-id> --agent <agent-id> [--json]"
  @assignments_progress_usage "jx assignments progress <assignment-id> --agent <agent-id> --summary <text> [--json]"
  @assignments_execute_usage "jx assignments execute <assignment-id> --agent <agent-id> --confirm [--json]"
  @assignments_fail_usage "jx assignments fail <assignment-id> --agent <agent-id> --summary <text> [--json]"
  @assignments_expire_usage "jx assignments expire [--json]"

  def usage_lines do
    [
      @assignments_create_usage,
      @assignments_ls_usage,
      @assignments_claim_usage,
      @assignments_start_usage,
      @assignments_progress_usage,
      @assignments_execute_usage,
      @assignments_fail_usage,
      @assignments_expire_usage
    ]
  end

  def usage do
    Enum.join(usage_lines(), " | ")
  end

  def run(["create", action_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [created_by: :string, ttl_seconds: :integer, json: :boolean]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @assignments_create_usage),
         :ok <- validate_optional_positive("ttl-seconds", parsed[:ttl_seconds]),
         :ok <- start_app(opts),
         {:ok, assignment} <-
           apply(workspace(opts), :create_assignment, [
             action_id,
             [
               created_by: parsed[:created_by] || "operator",
               ttl_seconds: parsed[:ttl_seconds] || 30 * 60
             ]
           ]) do
      print_assignment("created", assignment, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["ls" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [status: :string, agent: :string, workspace: :string, n: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @assignments_ls_usage),
         :ok <- validate_optional_assignment_status(parsed[:status]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:list_assignments, [
        [
          status: parsed[:status],
          agent_id: parsed[:agent],
          workspace_id: parsed[:workspace],
          limit: limit
        ]
      ])
      |> print_assignments(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["claim", assignment_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          agent: :string,
          runner: :string,
          session: :string,
          tmux_session: :string,
          log_path: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @assignments_claim_usage),
         :ok <- validate_assignment_claim_owner(parsed[:agent], parsed[:runner]),
         :ok <- start_app(opts) do
      if parsed[:runner] do
        with {:ok, result} <-
               apply(workspace(opts), :claim_runner_assignment, [
                 assignment_id,
                 parsed[:runner],
                 [
                   session_id: parsed[:session],
                   tmux_session_name: parsed[:tmux_session],
                   log_path: parsed[:log_path]
                 ]
               ]) do
          print_runner_assignment_claim(result, json: parsed[:json] || false)
          :ok
        end
      else
        with {:ok, assignment} <-
               apply(workspace(opts), :claim_assignment, [assignment_id, parsed[:agent]]) do
          print_assignment("claimed", assignment, json: parsed[:json] || false)
          :ok
        end
      end
    end
  end

  def run(["start", assignment_id | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [agent: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @assignments_start_usage),
         :ok <- validate_required_option("agent", parsed[:agent]),
         :ok <- start_app(opts),
         {:ok, assignment} <-
           apply(workspace(opts), :start_assignment, [assignment_id, parsed[:agent]]) do
      print_assignment("started", assignment, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["progress", assignment_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [agent: :string, summary: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @assignments_progress_usage),
         :ok <- validate_required_option("agent", parsed[:agent]),
         :ok <- validate_required_option("summary", parsed[:summary]),
         :ok <- start_app(opts),
         {:ok, assignment} <-
           apply(workspace(opts), :progress_assignment, [
             assignment_id,
             parsed[:agent],
             parsed[:summary]
           ]) do
      print_assignment("progressed", assignment, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["execute", assignment_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [agent: :string, confirm: :boolean, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @assignments_execute_usage),
         :ok <- validate_required_option("agent", parsed[:agent]),
         :ok <- start_app(opts) do
      if parsed[:confirm] do
        with {:ok, assignment} <-
               apply(workspace(opts), :execute_assignment, [
                 assignment_id,
                 parsed[:agent],
                 [confirm: true]
               ]) do
          print_assignment("executed", assignment, json: parsed[:json] || false)
          :ok
        end
      else
        {:error, "confirmation required; pass --confirm to execute this assignment"}
      end
    end
  end

  def run(["fail", assignment_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [agent: :string, summary: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @assignments_fail_usage),
         :ok <- validate_required_option("agent", parsed[:agent]),
         :ok <- validate_required_option("summary", parsed[:summary]),
         :ok <- start_app(opts),
         {:ok, assignment} <-
           apply(workspace(opts), :fail_assignment, [
             assignment_id,
             parsed[:agent],
             parsed[:summary]
           ]) do
      print_assignment("failed", assignment, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["expire" | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @assignments_expire_usage),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:expire_assignments, [])
      |> print_assignment_expiration(json: parsed[:json] || false)

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

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp validate_optional_positive(_name, nil), do: :ok
  defp validate_optional_positive(name, value), do: validate_positive(name, value)

  defp validate_required_option(name, nil), do: {:error, "--#{name} is required"}
  defp validate_required_option(name, ""), do: {:error, "--#{name} is required"}
  defp validate_required_option(_name, _value), do: :ok

  defp validate_assignment_claim_owner(nil, nil), do: {:error, "--agent or --runner is required"}
  defp validate_assignment_claim_owner("", nil), do: {:error, "--agent or --runner is required"}
  defp validate_assignment_claim_owner(nil, ""), do: {:error, "--agent or --runner is required"}

  defp validate_assignment_claim_owner(agent, runner)
       when agent not in [nil, ""] and runner not in [nil, ""],
       do: {:error, "use either --agent or --runner, not both"}

  defp validate_assignment_claim_owner(_agent, _runner), do: :ok

  defp validate_optional_assignment_status(nil), do: :ok

  defp validate_optional_assignment_status(status)
       when status in ~w(created claimed started progressed completed failed expired active all),
       do: :ok

  defp validate_optional_assignment_status(status),
    do:
      {:error,
       "unsupported assignment status #{inspect(status)}; expected created, claimed, started, progressed, completed, failed, expired, active, or all"}

  defp print_assignments(assignments, opts) do
    if opts[:json] do
      print_json(%{assignments: assignments})
    else
      if assignments == [] do
        IO.puts("no assignments")
      else
        rows =
          Enum.map(assignments, fn assignment ->
            [
              assignment.assignment_id,
              assignment.status,
              assignment.claimant_agent_id,
              assignment.runner_id,
              assignment.session_id,
              assignment.workspace_id,
              assignment.action_id,
              assignment.safe_action_kind,
              truncate(assignment.summary, 64),
              assignment.next
            ]
          end)

        print_table(
          [
            "ID",
            "STATUS",
            "AGENT",
            "RUNNER",
            "SESSION",
            "WORKSPACE",
            "ACTION",
            "KIND",
            "SUMMARY",
            "NEXT"
          ],
          rows
        )
      end
    end
  end

  defp print_runner_assignment_claim(result, opts) do
    packet = %{
      assignment: json_assignment(result.assignment),
      session: json_runner_session(result.session)
    }

    if opts[:json] do
      print_json(packet)
    else
      IO.puts("claimed #{packet.assignment.assignment_id}")
      IO.puts("runner: #{packet.session.runner_id}")
      IO.puts("session: #{packet.session.session_id}")
      IO.puts("tmux: #{packet.session.tmux_server}/#{packet.session.tmux_session_name}")
      IO.puts("next: jx sessions show #{packet.session.session_id}")
    end
  end

  defp print_assignment(label, assignment, opts) do
    packet = json_assignment(assignment)

    if opts[:json] do
      print_json(packet)
    else
      IO.puts("#{label} #{packet.assignment_id}")
      IO.puts("status: #{packet.status}")
      IO.puts("agent: #{blank_to_dash(packet.claimant_agent_id)}")
      IO.puts("runner: #{blank_to_dash(packet.runner_id)}")
      IO.puts("session: #{blank_to_dash(packet.session_id)}")
      IO.puts("workspace: #{blank_to_dash(packet.workspace_id)}")
      IO.puts("approval: #{blank_to_dash(packet.approval_id)}")
      IO.puts("action: #{packet.action_id}")
      IO.puts("kind: #{packet.safe_action_kind}")
      IO.puts("correlation_id: #{packet.correlation_id}")
      IO.puts("summary: #{blank_to_dash(packet.summary)}")
      IO.puts("next: #{assignment_next(packet)}")
    end
  end

  defp print_assignment_expiration(assignments, opts) do
    packets = Enum.map(assignments, &json_assignment/1)

    if opts[:json] do
      print_json(%{expired: packets})
    else
      IO.puts("expired #{length(packets)} assignment#{plural(length(packets))}")

      Enum.each(
        packets,
        &IO.puts("  #{&1.assignment_id} #{&1.action_id} #{&1.claimant_agent_id}")
      )
    end
  end

  defp json_assignment(%Assignment{} = assignment) do
    %{
      assignment_id: assignment.assignment_id,
      action_id: assignment.action_id,
      approval_id: assignment.approval_id,
      workspace_id: assignment.workspace_id,
      safe_action_kind: assignment.safe_action_kind,
      status: assignment.status,
      claimant_agent_id: assignment.claimant_agent_id,
      runner_id: assignment.runner_id,
      session_id: assignment.session_id,
      lease_id: assignment.lease_id,
      correlation_id: assignment.correlation_id,
      required_capabilities: decode_json_list(assignment.required_capabilities),
      summary: assignment.summary,
      claimed_at: assignment.claimed_at,
      started_at: assignment.started_at,
      last_report_at: assignment.last_report_at,
      completed_at: assignment.completed_at,
      expires_at: assignment.expires_at
    }
  end

  defp json_assignment(%{} = assignment), do: assignment

  defp json_runner_session(%RunnerSession{} = session) do
    %{
      session_id: session.session_id,
      runner_id: session.runner_id,
      agent_id: session.agent_id,
      assignment_id: session.assignment_id,
      workspace_id: session.workspace_id,
      action_id: session.action_id,
      approval_id: session.approval_id,
      status: session.status,
      correlation_id: session.correlation_id,
      tmux_server: session.tmux_server,
      tmux_session_name: session.tmux_session_name,
      log_path: session.log_path,
      last_summary: session.last_summary,
      started_at: session.started_at,
      heartbeat_at: session.heartbeat_at,
      ended_at: session.ended_at,
      expires_at: session.expires_at,
      next: runner_session_next(session)
    }
  end

  defp json_runner_session(%{} = session), do: session

  defp assignment_next(%{status: "created", assignment_id: id}),
    do: "jx assignments claim #{id} --agent <agent-id>"

  defp assignment_next(%{status: status, assignment_id: id})
       when status in ["claimed", "started", "progressed"],
       do: "jx assignments execute #{id} --agent <agent-id> --confirm"

  defp assignment_next(%{assignment_id: id}), do: "jx timeline assignment #{id}"

  defp runner_session_next(%{status: status, session_id: id})
       when status in ["claimed", "running", "progressed", "stale"],
       do: "jx sessions show #{id}"

  defp runner_session_next(%{session_id: id}), do: "jx timeline session #{id}"

  defp decode_json_list(value) when is_list(value), do: Enum.map(value, &to_string/1)

  defp decode_json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> Enum.map(decoded, &to_string/1)
      _other -> []
    end
  end

  defp decode_json_list(_value), do: []

  defp truncate(nil, _length), do: ""
  defp truncate(value, length) when byte_size(value) <= length, do: value
  defp truncate(value, length), do: binary_part(value, 0, max(length - 1, 0)) <> "..."

  defp blank_to_dash(value) when value in [nil, ""], do: "-"
  defp blank_to_dash(value), do: to_string(value)

  defp plural(1), do: ""
  defp plural(_count), do: "s"
end
