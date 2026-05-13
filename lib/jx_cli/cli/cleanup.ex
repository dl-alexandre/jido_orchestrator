defmodule JX.CLI.Cleanup do
  @moduledoc false

  alias JX.ResourceOwnerships

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @usage "jx cleanup --dry-run|audit [--owner-project <name>] [--type tmux_session|temp_path|worktree_path|task_dir|log_path] [--json]"

  def usage_lines, do: [@usage]

  def run(args, opts \\ [])

  def run(["audit" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [owner_project: :string, type: :string, json: :boolean]
      )

    audit_opts = [
      owner_project: parsed[:owner_project],
      resource_type: parsed[:type]
    ]

    workspace = opts[:workspace] || ResourceOwnerships

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @usage),
         :ok <- apply(opts[:start_app], []),
         {:ok, report} <- apply(workspace, :ownership_audit, [audit_opts]) do
      print_audit(report, json: parsed[:json] || false)
      :ok
    end
  end

  def run(args, opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          dry_run: :boolean,
          apply: :boolean,
          owner_project: :string,
          type: :string,
          json: :boolean
        ]
      )

    workspace = opts[:workspace] || ResourceOwnerships

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @usage),
         :ok <- validate_mode(parsed),
         :ok <- apply(opts[:start_app], []),
         {:ok, report} <- cleanup(parsed, workspace) do
      print_report(report, json: parsed[:json] || false)
      :ok
    end
  end

  defp print_audit(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("registered long-lived resources")

      print_table(
        ["resource", "owner", "type", "state", "reason"],
        Enum.map(report.registered_long_lived, fn item ->
          [
            item.resource,
            item.owner_type <> ":" <> item.owner_project,
            item.resource_type,
            item.state,
            item.reason
          ]
        end)
      )

      IO.puts("")
      IO.puts("known exempt creator paths")

      print_table(
        ["creator", "resource type", "policy", "reason"],
        Enum.map(report.exempt_creator_paths, fn item ->
          [
            item.creator,
            item.resource_type,
            item.cleanup_policy,
            item.reason
          ]
        end)
      )

      IO.puts("")
      IO.puts("unknown/unclassified: #{length(report.unknown_unclassified)}")
    end
  end

  defp validate_mode(opts) do
    cond do
      opts[:dry_run] && opts[:apply] -> {:error, "choose either --dry-run or --apply"}
      opts[:apply] -> :ok
      opts[:dry_run] -> :ok
      true -> {:error, "usage: #{@usage}"}
    end
  end

  defp cleanup(opts, workspace) do
    cleanup_opts = [
      owner_project: opts[:owner_project],
      resource_type: opts[:type]
    ]

    if opts[:apply] do
      apply(workspace, :cleanup_apply, [cleanup_opts])
    else
      apply(workspace, :cleanup_dry_run, [cleanup_opts])
    end
  end

  defp print_report(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      print_table(
        ["resource", "owned because", "status", "attached", "cleanup command"],
        Enum.map(report.resources, &row/1)
      )

      unless report.apply_available do
        IO.puts("")
        IO.puts("--apply is intentionally disabled for this milestone")
      end
    end
  end

  defp row(item) do
    [
      item.resource,
      item.why_owned,
      item.state <> "/" <> item.live_status,
      attached(item.attached),
      item.cleanup_command
    ]
  end

  defp attached(nil), do: "unknown"
  defp attached(true), do: "yes"
  defp attached(false), do: "no"
end
