defmodule JX.CLI.Fanout do
  @moduledoc false

  alias JX.Fanout

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @fanout_plan_usage "jx fanout plan <plan-id> --baseline <sha> [--base-branch <branch>] [--coverage-file <path> --host-count <n> --risk-rules <json-or-path>] [--host <name[=base,worktree_root,validation_prefix]>] [--root <dir>] [--run-id <id>] [--json]"
  @fanout_preflight_usage "jx fanout preflight <run-id-or-path> [--root <dir>] [--ttl-seconds <n>] [--json]"
  @fanout_launch_usage "jx fanout launch <run-id-or-path> [assignment-id|--all] [--root <dir>] [--lease-timeout-seconds <n>] [--codex-bin <path>] [--tmux-server <name>] [--json]"
  @fanout_monitor_usage "jx fanout monitor <run-id-or-path> [--root <dir>] [--json]"
  @fanout_ownership_usage "jx fanout ownership <run-id-or-path> <assignment-id> [--root <dir>] [--warn-only] [--json]"
  @fanout_pr_usage "jx fanout pr <run-id-or-path> <assignment-id> [--root <dir>] [--repo <owner/repo>] [--register-ci-watch] [--ci-watch-mode notify|hold|prompt] [--allow-unvalidated] [--json]"
  @fanout_status_usage "jx fanout status <run-id-or-path> [--root <dir>] [--json]"

  def usage do
    "#{@fanout_plan_usage} | #{@fanout_preflight_usage} | #{@fanout_launch_usage} | #{@fanout_monitor_usage} | #{@fanout_ownership_usage} | #{@fanout_pr_usage} | #{@fanout_status_usage}"
  end

  def run(["plan", plan_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          baseline: :string,
          base_branch: :string,
          root: :string,
          run_id: :string,
          coverage_file: :string,
          host_count: :integer,
          risk_rules: :string,
          host: :keep,
          base_path: :string,
          worktree_root: :string,
          validation_prefix: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @fanout_plan_usage),
         {:ok, baseline} <- required_option(parsed, :baseline, @fanout_plan_usage),
         {:ok, result} <-
           apply(fanout(opts), :plan, [
             plan_id,
             [
               baseline: baseline,
               base_branch: parsed[:base_branch],
               root: parsed[:root],
               run_id: parsed[:run_id],
               coverage_file: parsed[:coverage_file],
               host_count: parsed[:host_count],
               risk_rules: parsed[:risk_rules],
               host: Keyword.get_values(parsed, :host),
               base_path: parsed[:base_path],
               worktree_root: parsed[:worktree_root],
               validation_prefix: parsed[:validation_prefix]
             ]
           ]) do
      print_fanout_plan(result, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["preflight", run_ref | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [root: :string, ttl_seconds: :integer, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @fanout_preflight_usage),
         {:ok, result} <-
           apply(fanout(opts), :preflight, [
             run_ref,
             [
               root: parsed[:root],
               ttl_seconds: parsed[:ttl_seconds]
             ]
           ]) do
      print_fanout_preflight(result, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["launch", run_ref | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          all: :boolean,
          root: :string,
          lease_timeout_seconds: :integer,
          codex_bin: :string,
          tmux_server: :string,
          json: :boolean
        ]
      )

    target =
      case rest do
        [] -> :all
        [assignment_id] -> assignment_id
        _other -> :invalid
      end

    with :ok <- validate_options(invalid),
         :ok <- validate_launch_target(target, parsed[:all]),
         {:ok, result} <-
           apply(fanout(opts), :launch, [
             run_ref,
             target,
             [
               root: parsed[:root],
               lease_timeout_seconds: parsed[:lease_timeout_seconds],
               codex_bin: parsed[:codex_bin],
               tmux_server: parsed[:tmux_server]
             ]
           ]) do
      print_fanout_launch(result, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["monitor", run_ref | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [root: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @fanout_monitor_usage),
         :ok <- start_app(opts),
         {:ok, result} <- apply(fanout(opts), :monitor, [run_ref, [root: parsed[:root]]]) do
      print_fanout_monitor(result, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["ownership", run_ref, assignment_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [root: :string, warn_only: :boolean, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @fanout_ownership_usage),
         {:ok, result} <-
           apply(fanout(opts), :ownership_check, [
             run_ref,
             assignment_id,
             [
               root: parsed[:root],
               warn_only: parsed[:warn_only] || false
             ]
           ]) do
      print_fanout_ownership(result, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["pr", run_ref, assignment_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          root: :string,
          repo: :string,
          register_ci_watch: :boolean,
          ci_watch_mode: :string,
          allow_unvalidated: :boolean,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @fanout_pr_usage),
         :ok <- start_app(opts),
         {:ok, result} <-
           apply(fanout(opts), :open_pr, [
             run_ref,
             assignment_id,
             [
               root: parsed[:root],
               repo: parsed[:repo],
               register_ci_watch: Keyword.get(parsed, :register_ci_watch, true),
               ci_watch_mode: parsed[:ci_watch_mode],
               allow_unvalidated: parsed[:allow_unvalidated] || false
             ]
           ]) do
      print_fanout_pr(result, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["status", run_ref | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [root: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @fanout_status_usage),
         {:ok, status} <- apply(fanout(opts), :status, [run_ref, [root: parsed[:root]]]) do
      print_fanout_status(status, json: parsed[:json] || false)
      :ok
    end
  end

  def run(_args, _opts), do: {:error, "usage: #{usage()}"}

  defp fanout(opts), do: Keyword.get(opts, :fanout, Fanout)

  defp start_app(opts) do
    case Keyword.fetch(opts, :start_app) do
      {:ok, start_app} -> start_app.()
      :error -> {:error, :missing_start_app_callback}
    end
  end

  defp required_option(opts, key, usage) do
    case opts[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, "usage: #{usage}"}
    end
  end

  defp validate_launch_target(:invalid, _all?),
    do: {:error, "usage: #{@fanout_launch_usage}"}

  defp validate_launch_target(:all, _all?), do: :ok
  defp validate_launch_target(_assignment_id, false), do: :ok
  defp validate_launch_target(_assignment_id, nil), do: :ok

  defp validate_launch_target(_assignment_id, true),
    do: {:error, "use either --all or an assignment id, not both"}

  defp print_fanout_plan(result, json: true), do: print_json(result)

  defp print_fanout_plan(result, json: false) do
    IO.puts("fanout run planned")
    IO.puts("run: #{result.run_id}")
    IO.puts("path: #{result.run_path}")
    IO.puts("manifest: #{result.manifest_path}")
    IO.puts("assignments: #{result.assignment_count}")

    Enum.each(result.assignment_ids, &IO.puts("  #{&1}"))
  end

  defp print_fanout_preflight(result, json: true), do: print_json(result)

  defp print_fanout_preflight(result, json: false) do
    IO.puts("fanout preflight #{result.run_id}")
    IO.puts("path: #{result.run_path}")
    IO.puts("result: #{result.result}")
    IO.puts("")

    rows =
      Enum.map(result.assignments, fn assignment ->
        [
          assignment.assignment_id,
          assignment.host || "-",
          assignment.state || "-",
          assignment.publishability || "-",
          Enum.join(assignment.failed_checks || [], ", ")
        ]
      end)

    print_table(["assignment", "host", "state", "result", "failed checks"], rows)
  end

  defp print_fanout_launch(result, json: true), do: print_json(result)

  defp print_fanout_launch(result, json: false) do
    IO.puts("fanout launch #{result.run_id}")
    IO.puts("path: #{result.run_path}")
    IO.puts("")

    rows =
      Enum.map(result.assignments, fn assignment ->
        [
          assignment.assignment_id,
          assignment.state,
          assignment.agent_id,
          assignment.session_name,
          truncate(assignment.assignment_start_commit || "", 12),
          assignment.goal_status || "-"
        ]
      end)

    print_table(["assignment", "state", "agent", "session", "start", "goal"], rows)
  end

  defp print_fanout_monitor(result, json: true), do: print_json(result)

  defp print_fanout_monitor(result, json: false) do
    IO.puts("fanout monitor #{result.run_id}")
    IO.puts("path: #{result.run_path}")
    IO.puts("")

    rows =
      Enum.map(result.assignments, fn assignment ->
        watch = assignment.ci_watch || %{}

        [
          assignment.assignment_id,
          assignment.derived_state || "-",
          assignment.completion_state || "-",
          watch["watch_id"] || "-",
          watch["status"] || "-"
        ]
      end)

    print_table(["assignment", "state", "completion", "watch", "ci"], rows)
  end

  defp print_fanout_ownership(result, json: true), do: print_json(result)

  defp print_fanout_ownership(result, json: false) do
    IO.puts("fanout ownership #{result["assignment_id"]}")
    IO.puts("status: #{result["status"]}")

    unless result["warnings"] == [] do
      IO.puts("warnings: #{Enum.join(result["warnings"], "; ")}")
    end

    unless result["outside_write_paths"] == [] do
      IO.puts("outside write ownership:")
      Enum.each(result["outside_write_paths"], &IO.puts("- #{&1}"))
    end

    unless result["forbidden_touches"] == [] do
      IO.puts("forbidden touches:")
      Enum.each(result["forbidden_touches"], &IO.puts("- #{&1}"))
    end
  end

  defp print_fanout_pr(result, json: true), do: print_json(result)

  defp print_fanout_pr(result, json: false) do
    IO.puts("fanout PR #{result.assignment_id}")
    IO.puts("state: #{result.state}")
    IO.puts("url: #{result.pr["url"]}")

    if result.ci_watch do
      IO.puts("ci watch: #{result.ci_watch["watch_id"] || "-"}")
    end
  end

  defp print_fanout_status(status, json: true), do: print_json(status)

  defp print_fanout_status(status, json: false) do
    IO.puts("fanout status #{status.run_id}")
    IO.puts("path: #{status.run_path}")
    IO.puts("")

    rows =
      Enum.map(status.assignments, fn assignment ->
        [
          assignment.assignment_id,
          assignment.host || "-",
          assignment.branch || "-",
          assignment.orchestration_state || "-",
          assignment.derived_state || "-",
          assignment.completion_state || "-",
          to_string(assignment.report_count || 0)
        ]
      end)

    print_table(
      ["assignment", "host", "branch", "orchestration", "derived", "completion", "reports"],
      rows
    )
  end

  defp truncate(value, max_length) do
    value = value || ""

    if String.length(value) > max_length do
      String.slice(value, 0, max_length - 3) <> "..."
    else
      value
    end
  end
end
