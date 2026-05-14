defmodule JX.CLI.Project do
  @moduledoc false

  alias JX.SessionControls
  alias JX.SessionStatus
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @project_add_usage "jx project add <name> --host <host> --repo <path>"
  @project_audit_usage "jx project audit <name> [--host <host>] [--json]"
  @project_gate_usage "jx project gate <name> [--json]"
  @project_brief_usage "jx project brief <name> [--host <host>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--work-state <state>] [--control managed|ignored|protected|uncontrolled] [--no-observe] [--lines 80] [--scan-limit 100] [-n 5] [--json]"
  @project_ls_usage "jx project ls [--json]"
  @portfolio_summary_usage "jx portfolio summary [--host <host>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--work-state <state>] [--control managed|ignored|protected|uncontrolled] [--no-observe] [--lines 80] [--scan-limit 100] [-n 25] [--json]"
  @project_capacity_profile_usage "jx project capacity-profile <name> --host <host> --profile <profile>"
  @project_capacity_profiles_usage "jx project capacity-profiles"

  def usage do
    [
      @project_add_usage,
      @project_audit_usage,
      @project_gate_usage,
      @project_brief_usage,
      @project_ls_usage,
      @portfolio_summary_usage,
      @project_capacity_profile_usage,
      @project_capacity_profiles_usage
    ]
  end

  def usage_text do
    "usage: #{@project_add_usage} | #{@project_audit_usage} | #{@project_gate_usage} | #{@project_brief_usage} | #{@project_ls_usage}"
  end

  def run(["add", name | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [host: :string, repo: :string])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @project_add_usage),
         :ok <- start_app(opts),
         {:ok, project} <-
           apply(workspace(opts), :add_project, [
             %{
               name: name,
               host_name: parsed[:host],
               repo_path: parsed[:repo]
             }
           ]) do
      IO.puts(
        "project #{project.name} registered: host=#{parsed[:host]} repo=#{project.repo_path}"
      )

      :ok
    end
  end

  def run(["capacity-profile", name | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [host: :string, profile: :string])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @project_capacity_profile_usage),
         {:host, host_name} when is_binary(host_name) <- {:host, parsed[:host]},
         {:profile, profile_name} when is_binary(profile_name) <- {:profile, parsed[:profile]},
         :ok <- start_app(opts),
         {:ok, project} <-
           apply(workspace(opts), :set_project_capacity_profile, [name, host_name, profile_name]) do
      IO.puts("project #{project.name} capacity profile set to #{project.capacity_profile}")
      :ok
    else
      {:host, _} -> {:error, "usage: #{@project_capacity_profile_usage}"}
      {:profile, _} -> {:error, "usage: #{@project_capacity_profile_usage}"}
      other -> other
    end
  end

  def run(["capacity-profiles"], opts) do
    with :ok <- start_app(opts),
         {:ok, profiles} <- apply(workspace(opts), :list_capacity_profiles, []) do
      rows =
        profiles
        |> Map.values()
        |> Enum.sort_by(& &1.name)
        |> Enum.map(fn p ->
          [
            p.name,
            "#{p.ram_mb_per_slot} MB",
            "#{p.disk_mb_per_slot} MB",
            "#{p.cpu_cores_per_slot} cores"
          ]
        end)

      print_table(["PROFILE", "RAM/SLOT", "DISK/SLOT", "CPU/SLOT"], rows)
      :ok
    end
  end

  def run(["audit", name | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [host: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @project_audit_usage),
         :ok <- start_app(opts),
         {:ok, audit} <-
           apply(workspace(opts), :project_audit, [name, [host_name: parsed[:host]]]) do
      print_project_audit(audit, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["gate", name | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @project_gate_usage),
         :ok <- start_app(opts),
         {:ok, report} <- apply(workspace(opts), :project_gate, [name]) do
      print_project_gate(report, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["brief", name | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          work_state: :string,
          control: :string,
          observe: :boolean,
          lines: :integer,
          scan_limit: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    lines = parsed[:lines] || 80
    limit = parsed[:n] || 5
    scan_limit = parsed[:scan_limit] || max(limit * 5, 100)

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @project_brief_usage),
         :ok <- validate_optional_session_type(parsed[:type]),
         :ok <- validate_optional_work_state(parsed[:work_state]),
         :ok <- validate_optional_work_board_control(parsed[:control]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts),
         {:ok, brief} <-
           apply(workspace(opts), :project_brief, [
             name,
             [
               host_name: parsed[:host],
               all_tmux: !parsed[:managed],
               all_processes: parsed[:all_processes] || false,
               type: parsed[:type],
               ssh_target: parsed[:ssh_target],
               work_state: parsed[:work_state],
               control_mode: parsed[:control],
               observe: Keyword.get(parsed, :observe, true),
               lines: lines,
               scan_limit: scan_limit,
               limit: limit
             ]
           ]) do
      print_project_brief(brief, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["ls" | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @project_ls_usage),
         :ok <- start_app(opts) do
      opts
      |> workspace()
      |> apply(:list_projects, [])
      |> print_projects(json: parsed[:json] || false)

      :ok
    end
  end

  def run(_args, _opts), do: {:error, usage_text()}

  defp start_app(opts) do
    case Keyword.fetch(opts, :start_app) do
      {:ok, start_app} -> start_app.()
      :error -> {:error, :missing_start_app_callback}
    end
  end

  defp workspace(opts), do: Keyword.get(opts, :workspace, Workspace)

  defp validate_optional_session_type(nil), do: :ok

  defp validate_optional_session_type(type) do
    if type in ~w(agent process ssh task tmux) do
      :ok
    else
      {:error,
       "unsupported session type #{inspect(type)}; expected one of: agent, process, ssh, task, tmux"}
    end
  end

  defp validate_optional_work_state(nil), do: :ok

  defp validate_optional_work_state(work_state) do
    if work_state in SessionStatus.work_states() do
      :ok
    else
      {:error,
       "unsupported work state #{inspect(work_state)}; expected one of: #{Enum.join(SessionStatus.work_states(), ", ")}"}
    end
  end

  defp validate_optional_work_board_control(nil), do: :ok
  defp validate_optional_work_board_control("uncontrolled"), do: :ok
  defp validate_optional_work_board_control(mode), do: validate_session_control_mode(mode)

  defp validate_session_control_mode(mode) do
    if mode in SessionControls.modes() do
      :ok
    else
      {:error,
       "unsupported session control mode #{inspect(mode)}; expected one of: #{Enum.join(SessionControls.modes(), ", ")}"}
    end
  end

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp print_projects([], opts) do
    if opts[:json] do
      print_json(%{projects: []})
    else
      IO.puts("no projects")
    end
  end

  defp print_projects(projects, opts) do
    if opts[:json] do
      print_json(%{projects: Enum.map(projects, &json_project/1)})
    else
      rows =
        Enum.map(projects, fn project ->
          host = Map.get(project, :host)

          [
            project.name,
            project.slug,
            (host && host.name) || "",
            (host && host.transport) || "",
            (host && host.ssh_target) || "",
            project.repo_path
          ]
        end)

      print_table(["PROJECT", "SLUG", "HOST", "TRANSPORT", "SSH", "REPO"], rows)
    end
  end

  defp json_project(project) do
    host = Map.get(project, :host)

    %{
      name: project.name,
      slug: project.slug,
      repo_path: project.repo_path,
      host: (host && host.name) || "",
      transport: (host && host.transport) || "",
      ssh_target: (host && host.ssh_target) || "",
      workspace_path: (host && host.workspace_path) || ""
    }
  end

  defp print_project_audit(audit, json: true), do: print_json(%{project_audit: audit})

  defp print_project_audit(audit, json: false) do
    IO.puts("project audit #{audit.project}")
    print_summary_counts("summary", audit.summary)

    unless audit.warnings == [] do
      IO.puts("warnings: #{Enum.join(audit.warnings, "; ")}")
    end

    rows =
      Enum.map(audit.instances, fn instance ->
        [
          instance.host,
          instance.status,
          instance.branch,
          truncate(instance.head, 12),
          instance.upstream,
          format_optional_integer(instance.ahead),
          format_optional_integer(instance.behind),
          if(instance.dirty, do: "yes", else: "no"),
          Integer.to_string(length(instance.changes)),
          truncate(Enum.join(instance.warnings, "; "), 48),
          truncate(instance.repo_path, 80)
        ]
      end)

    print_table(
      [
        "HOST",
        "STATUS",
        "BRANCH",
        "HEAD",
        "UPSTREAM",
        "AHEAD",
        "BEHIND",
        "DIRTY",
        "CHG",
        "WARN",
        "REPO"
      ],
      rows
    )
  end

  defp print_project_gate(report, json: true), do: print_json(%{project_gate: report})

  defp print_project_gate(report, json: false) do
    IO.puts("Project: #{report.project}")
    IO.puts("Promotion eligible: #{yes_no(report.eligible)}")
    IO.puts("Status: #{report.status}")
    IO.puts("")
    IO.puts("Hosts:")

    case report.hosts do
      [] ->
        IO.puts("- none")

      hosts ->
        Enum.each(hosts, fn host ->
          IO.puts("- #{host.host}: #{host.status} - #{project_gate_reasons(host.reasons)}")
        end)
    end

    IO.puts("")
    print_project_gate_list("Required fixes", report.required_fixes)
  end

  defp project_gate_reasons([]), do: "none"
  defp project_gate_reasons(reasons), do: Enum.join(reasons, ", ")

  defp print_project_gate_list(title, []), do: IO.puts("#{title}:\n- none")

  defp print_project_gate_list(title, items) do
    IO.puts("#{title}:")
    Enum.each(items, &IO.puts("- #{&1}"))
  end

  defp print_project_brief(brief, json: true), do: print_json(%{project_brief: brief})

  defp print_project_brief(brief, json: false) do
    project = Map.get(brief, :project, %{})
    next_step = Map.get(brief, :next, %{})
    mode = Map.get(brief, :mode, %{})
    counts = Map.get(brief, :counts, %{})

    IO.puts("project #{Map.get(project, :name, "")}")
    IO.puts("headline: #{Map.get(brief, :headline, "")}")
    IO.puts("next: #{Map.get(next_step, :next, "")}")
    IO.puts("mode: #{Map.get(mode, :id, "")} - #{Map.get(mode, :title, "")}")
    IO.puts("command: #{Map.get(next_step, :command, "")}")
    IO.puts("")

    print_summary_counts("project", counts)

    refs = Map.get(brief, :refs, [])

    unless refs == [] do
      IO.puts("")

      rows =
        Enum.map(refs, fn ref ->
          [
            Map.get(ref, :ref, ""),
            Map.get(ref, :state, ""),
            Map.get(ref, :work_state, ""),
            Map.get(ref, :prompt_status, ""),
            Map.get(ref, :control_mode, ""),
            truncate(Map.get(ref, :next_step, ""), 72)
          ]
        end)

      print_table(["REF", "STATE", "WORK", "PROMPT", "CONTROL", "NEXT"], rows)
    end

    agenda = Map.get(brief, :agenda, [])

    unless agenda == [] do
      IO.puts("")

      rows =
        Enum.map(agenda, fn item ->
          [
            Map.get(item, :kind, ""),
            Map.get(item, :project, ""),
            Map.get(item, :ref, ""),
            Map.get(item, :id, ""),
            truncate(Map.get(item, :label, ""), 96)
          ]
        end)

      print_table(["KIND", "PROJECT", "REF", "ID", "LABEL"], rows)
    end
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
          [[to_string(key), "", yes_no(value)]]

        {key, value} when is_binary(value) ->
          [[to_string(key), "", value]]

        _other ->
          []
      end)

    IO.puts(name)
    print_table(["METRIC", "KEY", "VALUE"], rows)
  end

  defp summary_value(value) when is_integer(value), do: Integer.to_string(value)
  defp summary_value(value) when is_boolean(value), do: yes_no(value)
  defp summary_value(value) when is_binary(value), do: value
  defp summary_value(%_struct{} = value), do: to_string(value)
  defp summary_value(nil), do: ""
  defp summary_value(value), do: inspect(value)

  defp format_optional_integer(nil), do: ""
  defp format_optional_integer(integer), do: Integer.to_string(integer)

  defp truncate(value, max_length) do
    value = value || ""

    if String.length(value) > max_length do
      String.slice(value, 0, max_length - 3) <> "..."
    else
      value
    end
  end

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
end
