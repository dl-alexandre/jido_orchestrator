defmodule JX.CLI.Runtimes do
  @moduledoc false

  alias JX.RuntimeEnvironments
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @runtimes_provision_usage "jx runtimes provision <action-id> --project <project> [--host <host>] [--runner <runner-id>] [--tool <tool>] [--capability <cap>] [--os <os>] [--branch-isolation worktree] [--concurrency-limit 1] [--ttl-seconds 86400] [--json]"
  @runtimes_assign_usage "jx runtimes assign <runtime-id> <action-id> [--runner <runner-id>] [--session <session-id>] [--ttl-seconds 86400] [--json]"
  @runtimes_ls_usage "jx runtimes ls [--status planned|provisioning|ready|assigned|released|failed|expired|active|all] [--workspace <id>] [--runner <id>] [-n 50] [--json]"
  @runtimes_show_usage "jx runtimes show <runtime-id> [--json]"
  @runtimes_release_usage "jx runtimes release <runtime-id> [--json]"
  @usage_note "Runtime commands manage placement and worktree lifecycle evidence only. They route approved safe actions to isolated environments; DevIDE still resolves executable safe actions."

  def usage_lines do
    [
      @runtimes_ls_usage,
      @runtimes_provision_usage,
      @runtimes_assign_usage,
      @runtimes_show_usage,
      @runtimes_release_usage,
      "",
      @usage_note
    ]
  end

  def usage do
    [
      @runtimes_ls_usage,
      @runtimes_provision_usage,
      @runtimes_assign_usage,
      @runtimes_show_usage,
      @runtimes_release_usage
    ]
    |> Enum.join(" | ")
  end

  def run(["provision", action_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          project: :string,
          host: :string,
          runner: :string,
          tool: :keep,
          capability: :keep,
          os: :string,
          branch_isolation: :string,
          concurrency_limit: :integer,
          ttl_seconds: :integer,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @runtimes_provision_usage),
         :ok <- validate_required_option("project", parsed[:project]),
         :ok <- validate_optional_positive("concurrency-limit", parsed[:concurrency_limit]),
         :ok <- validate_optional_positive("ttl-seconds", parsed[:ttl_seconds]),
         :ok <- start_app(opts),
         {:ok, runtime} <-
           apply(workspace(opts), :provision_runtime_for_action, [
             action_id,
             [
               project: parsed[:project],
               host: parsed[:host],
               runner_id: parsed[:runner],
               tools: Keyword.get_values(parsed, :tool),
               capabilities: Keyword.get_values(parsed, :capability),
               os: parsed[:os],
               branch_isolation: parsed[:branch_isolation] || "worktree",
               concurrency_limit: parsed[:concurrency_limit] || 1,
               ttl_seconds: parsed[:ttl_seconds] || 24 * 60 * 60
             ]
           ]) do
      print_runtime("provisioned", runtime, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["assign", runtime_id, action_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          runner: :string,
          session: :string,
          ttl_seconds: :integer,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @runtimes_assign_usage),
         :ok <- validate_optional_positive("ttl-seconds", parsed[:ttl_seconds]),
         :ok <- start_app(opts),
         {:ok, result} <-
           apply(workspace(opts), :assign_runtime_action, [
             runtime_id,
             action_id,
             [
               runner_id: parsed[:runner],
               session_id: parsed[:session],
               ttl_seconds: parsed[:ttl_seconds] || 24 * 60 * 60
             ]
           ]) do
      print_runtime_assignment(result, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["release", runtime_id | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @runtimes_release_usage),
         :ok <- start_app(opts),
         {:ok, runtime} <- apply(workspace(opts), :release_runtime, [runtime_id]) do
      print_runtime("released", runtime, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["show", runtime_id | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @runtimes_show_usage),
         :ok <- start_app(opts) do
      case apply(workspace(opts), :get_runtime_environment, [runtime_id]) do
        nil ->
          {:error, :runtime_not_found}

        runtime ->
          print_runtime("runtime", runtime, json: parsed[:json] || false)
          :ok
      end
    end
  end

  def run(["ls" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          status: :string,
          workspace: :string,
          runner: :string,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @runtimes_ls_usage),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:list_runtime_environments, [
        [
          status: parsed[:status] || "active",
          workspace_id: parsed[:workspace],
          runner_id: parsed[:runner],
          limit: limit
        ]
      ])
      |> print_runtimes(json: parsed[:json] || false)

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

  defp print_runtimes(runtimes, opts) do
    if opts[:json] do
      print_json(%{runtimes: runtimes})
    else
      print_dashboard_list("runtime environments", runtimes, [
        :runtime_id,
        :status,
        :workspace_id,
        :host_name,
        :runner_id,
        :assignment_id,
        :worktree_path
      ])
    end
  end

  defp print_runtime(label, runtime, opts) do
    runtime = runtime_summary(runtime)

    if opts[:json] do
      print_json(%{runtime: runtime})
    else
      IO.puts("#{label} #{runtime.runtime_id}")

      print_summary_counts(
        "runtime",
        Map.take(runtime, [
          :status,
          :workspace_id,
          :action_id,
          :assignment_id,
          :runner_id,
          :host_name,
          :worktree_path,
          :branch,
          :branch_isolation,
          :concurrency_limit
        ])
      )
    end
  end

  defp print_runtime_assignment(result, opts) do
    if opts[:json] do
      print_json(%{
        runtime: runtime_summary(result.runtime),
        assignment: runtime_assignment_summary(result.assignment)
      })
    else
      IO.puts("assigned runtime #{result.runtime.runtime_id}")
      IO.puts("assignment: #{result.assignment.assignment_id}")
      IO.puts("status: #{result.assignment.status}")
      IO.puts("runner: #{blank_to_dash(result.runtime.runner_id)}")
    end
  end

  defp runtime_assignment_summary(%{} = assignment) do
    Map.take(assignment, [
      :assignment_id,
      :action_id,
      :approval_id,
      :workspace_id,
      :safe_action_kind,
      :status,
      :claimant_agent_id,
      :runner_id,
      :session_id,
      :lease_id,
      :correlation_id,
      :summary
    ])
  end

  defp runtime_summary(%{} = runtime) do
    if Map.has_key?(runtime, :runtime_id) and is_list(Map.get(runtime, :capabilities)) do
      runtime
    else
      RuntimeEnvironments.summary(runtime)
    end
  end

  defp print_dashboard_list(label, [], _fields) do
    IO.puts("")
    IO.puts("#{label}: none")
  end

  defp print_dashboard_list(label, items, fields) do
    IO.puts("")
    IO.puts(label)

    rows =
      Enum.map(items, fn item ->
        Enum.map(fields, fn field ->
          item
          |> Map.get(field, "")
          |> dashboard_value()
        end)
      end)

    fields
    |> Enum.map(&(&1 |> Atom.to_string() |> String.upcase()))
    |> print_table(rows)
  end

  defp print_summary_counts(name, counts) do
    rows =
      counts
      |> Enum.flat_map(fn
        {key, %_struct{} = value} ->
          [[to_string(key), "", to_string(value)]]

        {key, value} when is_map(value) ->
          value
          |> Enum.map(fn {nested_key, nested_value} ->
            [to_string(key), to_string(nested_key), summary_value(nested_value)]
          end)

        {key, value} when is_integer(value) ->
          [[to_string(key), "", Integer.to_string(value)]]

        {key, value} when is_boolean(value) ->
          [[to_string(key), "", format_bool(value)]]

        {key, value} when is_binary(value) ->
          [[to_string(key), "", value]]

        _other ->
          []
      end)

    IO.puts(name)
    print_table(["METRIC", "KEY", "VALUE"], rows)
  end

  defp dashboard_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp dashboard_value(value) when is_list(value),
    do: Enum.map_join(value, ",", &dashboard_value/1)

  defp dashboard_value(value) when is_map(value), do: Jason.encode!(value)
  defp dashboard_value(value), do: value |> blank_to_dash() |> truncate(80)

  defp summary_value(value) when is_integer(value), do: Integer.to_string(value)
  defp summary_value(value) when is_boolean(value), do: format_bool(value)
  defp summary_value(value) when is_binary(value), do: value
  defp summary_value(%_struct{} = value), do: to_string(value)
  defp summary_value(nil), do: ""
  defp summary_value(value), do: inspect(value)

  defp blank_to_dash(value) when value in [nil, ""], do: "-"
  defp blank_to_dash(value), do: to_string(value)

  defp truncate(nil, _max_length), do: ""

  defp truncate(value, max_length) do
    if String.length(value) > max_length do
      String.slice(value, 0, max_length - 3) <> "..."
    else
      value
    end
  end

  defp format_bool(true), do: "yes"
  defp format_bool(false), do: "no"
end
