defmodule JX.CLI.Session do
  @moduledoc false

  alias JX.AgentRunner
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @capture_usage "jx session capture <ref> [-n 80]"
  @attach_usage "jx session attach <ref>"
  @inspect_usage "jx session inspect <ref> [--json]"
  @profile_usage "jx session profile <ref> [--summary <text>] [--objective <text>] [--expect <text>] [--next-prompt <text>] [--prompt-status none|draft|ready|sent|blocked] [--strategy <text>] [--notes <text>] [--owner <name>] [--risk low|normal|high|blocked] [--lifecycle active|parked|done|blocked] [--hypothesis <text>] [--evidence <text>] [--stale-after <seconds>] [--no-observe] [--lines 40] [--json]"
  @mark_usage "jx session mark <ref> --mode managed|ignored|protected [--project <name>] [--note <text>]"
  @unmark_usage "jx session unmark <ref>"
  @send_usage "jx session send <ref> \"<message>\" [--no-enter]"
  @key_usage "jx session key <ref> \"<keys>\" [--no-enter] [--json]"
  @probe_usage "jx session probe <ref> [--force] [--timeout-ms 5000] [--json]"
  @resume_adopt_usage "jx session resume-adopt <ref> <project> [--agent claude|opencode|codex] [--relaunch] [--json]"
  @stream_adopt_usage "jx session stream-adopt <ref> <project> [--agent claude|opencode|codex] [--transport native|acpx] [--relaunch] [--json]"
  @adopt_usage "jx session adopt <ref> <project> [--agent claude|opencode|codex]"

  def usage_lines do
    [
      @capture_usage,
      @attach_usage,
      @inspect_usage,
      @profile_usage,
      @mark_usage,
      @unmark_usage,
      @send_usage,
      @key_usage,
      @probe_usage,
      @resume_adopt_usage,
      @stream_adopt_usage,
      @adopt_usage
    ]
  end

  def usage, do: Enum.join(usage_lines(), " | ")

  def run(["capture", ref | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [n: :integer], aliases: [n: :n])

    lines = parsed[:n] || 80

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @capture_usage),
         :ok <- validate_positive("n", lines),
         :ok <- start_app(opts),
         {:ok, output} <- apply(workspace(opts), :capture_session, [ref, [lines: lines]]) do
      IO.write(output)
      :ok
    end
  end

  def run(["attach", ref | args], opts) do
    {_parsed, rest, invalid} = OptionParser.parse(args, strict: [])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @attach_usage),
         :ok <- start_app(opts) do
      apply(workspace(opts), :attach_session, [ref])
    end
  end

  def run(["inspect", ref | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @inspect_usage),
         :ok <- start_app(opts),
         {:ok, session} <- apply(workspace(opts), :get_session, [ref]) do
      print_session_inspection(session, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["profile", ref | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          summary: :string,
          objective: :string,
          expect: :string,
          next_prompt: :string,
          prompt_status: :string,
          strategy: :string,
          notes: :string,
          owner: :string,
          risk: :string,
          lifecycle: :string,
          hypothesis: :string,
          evidence: :string,
          stale_after: :integer,
          observe: :boolean,
          lines: :integer,
          json: :boolean
        ]
      )

    lines = parsed[:lines] || 40
    attrs = session_profile_attrs(parsed)

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @profile_usage),
         :ok <- validate_optional_prompt_status(parsed[:prompt_status]),
         :ok <- validate_optional_risk_level(parsed[:risk]),
         :ok <- validate_optional_lifecycle_status(parsed[:lifecycle]),
         :ok <- validate_optional_positive("stale-after", parsed[:stale_after]),
         :ok <- validate_positive("lines", lines),
         :ok <- start_app(opts),
         :ok <- maybe_set_session_profile(opts, ref, attrs),
         {:ok, report} <-
           apply(workspace(opts), :session_profiles, [
             [
               ref: ref,
               observe: Keyword.get(parsed, :observe, true),
               lines: lines,
               limit: 1
             ]
           ]) do
      print_session_profiles(report, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["mark", ref | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [mode: :string, project: :string, note: :string])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @mark_usage),
         {:ok, mode} <- required_option(parsed, :mode, @mark_usage),
         :ok <- validate_session_control_mode(mode),
         :ok <- start_app(opts),
         {:ok, control} <-
           apply(workspace(opts), :set_session_control, [
             ref,
             mode,
             [
               project: parsed[:project] || "",
               note: parsed[:note] || ""
             ]
           ]) do
      IO.puts("session #{control.ref} marked #{control.mode}")
      :ok
    end
  end

  def run(["unmark", ref | args], opts) do
    {_parsed, rest, invalid} = OptionParser.parse(args, strict: [])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @unmark_usage),
         :ok <- start_app(opts),
         {:ok, _control} <- apply(workspace(opts), :clear_session_control, [ref]) do
      IO.puts("session #{ref} unmarked")
      :ok
    end
  end

  def run(["send", ref | args], opts) do
    {parsed, message_parts, invalid} =
      OptionParser.parse(args, strict: [no_enter: :boolean])

    message = message_parts |> Enum.join(" ") |> String.trim()

    with :ok <- validate_options(invalid),
         {:ok, message} <- required_message(message, @send_usage),
         :ok <- start_app(opts),
         {:ok, directive} <-
           apply(workspace(opts), :send_session_prompt, [
             ref,
             message,
             [enter: !parsed[:no_enter]]
           ]) do
      IO.puts("directive #{directive.directive_id} sent to session #{ref}")
      :ok
    end
  end

  def run(["key", ref | args], opts) do
    {parsed, key_parts, invalid} =
      OptionParser.parse(args, strict: [no_enter: :boolean, json: :boolean])

    keys = key_parts |> Enum.join(" ") |> String.trim()

    with :ok <- validate_options(invalid),
         {:ok, keys} <- required_message(keys, @key_usage),
         :ok <- start_app(opts),
         {:ok, result} <-
           apply(workspace(opts), :send_session_keys, [ref, keys, [enter: !parsed[:no_enter]]]) do
      if parsed[:json], do: print_json(result), else: IO.puts("sent keys to session #{ref}")
      :ok
    end
  end

  def run(["probe", ref | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [timeout_ms: :integer, force: :boolean, json: :boolean])

    timeout_ms = parsed[:timeout_ms] || 5_000

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @probe_usage),
         :ok <- validate_positive("timeout-ms", timeout_ms),
         :ok <- start_app(opts),
         {:ok, probe} <-
           apply(workspace(opts), :probe_session, [
             ref,
             [timeout_ms: timeout_ms, force: parsed[:force] || false]
           ]) do
      print_session_probe(probe, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["stream-adopt", ref, project_name | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [agent: :string, transport: :string, relaunch: :boolean, json: :boolean]
      )

    agent_name = parsed[:agent]
    agent_transport = parsed[:transport] || AgentRunner.default_agent_transport()

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @stream_adopt_usage),
         :ok <- validate_optional_agent_name(agent_name),
         :ok <- validate_agent_transport(agent_transport),
         :ok <- start_app(opts),
         {:ok, adoption} <-
           apply(workspace(opts), :stream_adopt_session, [
             ref,
             project_name,
             [
               agent_name: agent_name,
               agent_transport: agent_transport,
               relaunch: parsed[:relaunch] || false
             ]
           ]) do
      print_stream_adoption(adoption, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["resume-adopt", ref, project_name | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [agent: :string, relaunch: :boolean, json: :boolean])

    agent_name = parsed[:agent]

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @resume_adopt_usage),
         :ok <- validate_optional_agent_name(agent_name),
         :ok <- start_app(opts),
         {:ok, adoption} <-
           apply(workspace(opts), :resume_adopt_session, [
             ref,
             project_name,
             [agent_name: agent_name, relaunch: parsed[:relaunch] || false]
           ]) do
      print_stream_adoption(adoption, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["adopt", ref, project_name | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [agent: :string])
    agent_name = parsed[:agent] || "claude"

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @adopt_usage),
         :ok <- validate_agent_name(agent_name),
         :ok <- start_app(opts),
         {:ok, task} <-
           apply(workspace(opts), :adopt_session, [ref, project_name, [agent_name: agent_name]]) do
      IO.puts("""
      task #{task.task_id} adopted from session #{ref}
      branch: #{task.branch}
      worktree: #{task.worktree_path}
      server: #{task.tmux_server}
      session: #{task.session_name}
      pane: #{task.window}.#{task.pane}
      log: #{task.log_path}
      """)

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

  defp validate_agent_name(agent_name) do
    if agent_name in AgentRunner.agent_names() do
      :ok
    else
      {:error,
       "unsupported agent #{inspect(agent_name)}; expected one of: #{Enum.join(AgentRunner.agent_names(), ", ")}"}
    end
  end

  defp validate_optional_agent_name(nil), do: :ok
  defp validate_optional_agent_name(agent_name), do: validate_agent_name(agent_name)

  defp validate_agent_transport(agent_transport) do
    if agent_transport in AgentRunner.agent_transports() do
      :ok
    else
      {:error,
       "unsupported agent transport #{inspect(agent_transport)}; expected one of: #{Enum.join(AgentRunner.agent_transports(), ", ")}"}
    end
  end

  defp validate_session_control_mode(mode) do
    if mode in JX.SessionControls.modes() do
      :ok
    else
      {:error,
       "unsupported session control mode #{inspect(mode)}; expected one of: #{Enum.join(JX.SessionControls.modes(), ", ")}"}
    end
  end

  defp validate_optional_prompt_status(nil), do: :ok

  defp validate_optional_prompt_status(status) do
    statuses = JX.SessionProfiles.prompt_statuses()

    if status in statuses do
      :ok
    else
      {:error,
       "unsupported prompt status #{inspect(status)}; expected one of: #{Enum.join(statuses, ", ")}"}
    end
  end

  defp validate_optional_risk_level(nil), do: :ok

  defp validate_optional_risk_level(risk) do
    if risk in ~w(low normal high blocked) do
      :ok
    else
      {:error, "unsupported risk #{inspect(risk)}; expected one of: low, normal, high, blocked"}
    end
  end

  defp validate_optional_lifecycle_status(nil), do: :ok

  defp validate_optional_lifecycle_status(status) do
    if status in ~w(active parked done blocked) do
      :ok
    else
      {:error,
       "unsupported lifecycle #{inspect(status)}; expected one of: active, parked, done, blocked"}
    end
  end

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp validate_optional_positive(_name, nil), do: :ok
  defp validate_optional_positive(name, value), do: validate_positive(name, value)

  defp required_option(opts, key, usage) do
    case opts[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, "usage: #{usage}"}
    end
  end

  defp required_message(message, _usage) when is_binary(message) and message != "" do
    {:ok, message}
  end

  defp required_message(_message, usage), do: {:error, "usage: #{usage}"}

  defp session_profile_attrs(opts) do
    %{}
    |> put_present(:summary, opts[:summary])
    |> put_present(:objective, opts[:objective])
    |> put_present(:expected_completion, opts[:expect])
    |> put_present(:next_prompt, opts[:next_prompt])
    |> put_present(:prompt_status, opts[:prompt_status])
    |> put_present(:strategy, opts[:strategy])
    |> put_present(:notes, opts[:notes])
    |> put_present(:owner, opts[:owner])
    |> put_present(:risk_level, opts[:risk])
    |> put_present(:lifecycle_status, opts[:lifecycle])
    |> put_present(:current_hypothesis, opts[:hypothesis])
    |> put_present(:last_evidence, opts[:evidence])
    |> put_present(:stale_after_seconds, opts[:stale_after])
  end

  defp put_present(attrs, _key, nil), do: attrs
  defp put_present(attrs, key, value), do: Map.put(attrs, key, value)

  defp maybe_set_session_profile(_opts, _ref, attrs) when map_size(attrs) == 0, do: :ok

  defp maybe_set_session_profile(opts, ref, attrs) do
    with {:ok, _profile} <- apply(workspace(opts), :set_session_profile, [ref, attrs]), do: :ok
  end

  defp print_session_probe(probe, opts) do
    if opts[:json] do
      print_json(probe)
    else
      print_session_probe_table(probe)
    end
  end

  defp print_stream_adoption(adoption, opts) do
    if opts[:json] do
      print_json(adoption)
    else
      print_stream_adoption_text(adoption)
    end
  end

  defp print_stream_adoption_text(%{status: "relaunched"} = adoption) do
    task = adoption.task

    IO.puts("""
    task #{task.task_id} relaunched from session #{adoption.ref}
    agent: #{task.agent_name}
    transport: #{task.agent_transport}
    branch: #{task.branch}
    worktree: #{task.worktree_path}
    server: #{task.tmux_server}
    session: #{task.session_name}
    pane: #{task.window}.#{task.pane}
    log: #{task.log_path}
    """)
  end

  defp print_stream_adoption_text(%{status: "adopted"} = adoption) do
    task = adoption.task

    IO.puts("""
    task #{task.task_id} adopted from session #{adoption.ref}
    agent: #{task.agent_name}
    transport: #{task.agent_transport}
    branch: #{task.branch}
    worktree: #{task.worktree_path}
    server: #{task.tmux_server}
    session: #{task.session_name}
    pane: #{task.window}.#{task.pane}
    log: #{task.log_path}
    """)
  end

  defp print_stream_adoption_text(%{status: "resume-available"} = adoption) do
    session = adoption.session
    next_action = adoption.next_action

    IO.puts("session #{adoption.ref} can be resume-adopted")
    IO.puts("reason: #{adoption.reason}")
    IO.puts("process: #{session.kind} role=#{session.process_role} pid=#{session.pid || ""}")
    IO.puts("resume: #{adoption.resume_ref}")
    IO.puts("workspace: #{adoption.zed_workspace}")
    IO.puts("next: #{next_action.command}")
  end

  defp print_stream_adoption_text(adoption) do
    session = adoption.session
    next_action = adoption.next_action

    IO.puts("session #{adoption.ref} needs managed stream bridge")
    IO.puts("reason: #{adoption.reason}")
    IO.puts("process: #{session.kind} pid=#{session.pid || ""} tty=#{session.tty || ""}")
    IO.puts("next: #{next_action.command}")
  end

  defp print_session_probe_table(probe) do
    print_table(
      ["REF", "SSH_TARGET", "PANE", "TMUX", "SESSIONS", "DETAIL"],
      [
        [
          probe.ref,
          probe.ssh_target,
          probe.target,
          probe.tmux,
          Integer.to_string(probe.sessions),
          truncate(Map.get(probe, :detail, ""), 120)
        ]
      ]
    )

    print_remote_sessions(Map.get(probe, :remote_sessions, []))
  end

  defp print_session_inspection(session, opts) do
    if opts[:json] do
      print_json(session)
    else
      print_session_inspection_table(session)
    end
  end

  defp print_session_inspection_table(session) do
    rows = [
      ["ref", Map.get(session, :ref, "")],
      ["host", Map.get(session, :host, "")],
      ["transport", Map.get(session, :transport, "")],
      ["type", Map.get(session, :type, "")],
      ["state", Map.get(session, :state, "")],
      ["control", Map.get(session, :control_mode, "uncontrolled")],
      ["control_project", Map.get(session, :control_project, "")],
      ["control_note", Map.get(session, :control_note, "")],
      ["kind", Map.get(session, :kind, "")],
      ["agent", Map.get(session, :agent_name, "")],
      ["task", Map.get(session, :task_id, "")],
      ["server", Map.get(session, :server, "")],
      ["session", Map.get(session, :session, "")],
      ["window", format_optional_integer(Map.get(session, :window))],
      ["pane", format_optional_integer(Map.get(session, :pane))],
      ["tty", Map.get(session, :tty, "")],
      ["active", format_active(Map.get(session, :active))],
      ["pid", format_optional_integer(Map.get(session, :pid))],
      ["stat", Map.get(session, :stat, "")],
      ["ssh_target", Map.get(session, :ssh_target, "")],
      ["registered_host", Map.get(session, :registered_host, "")],
      ["actions", Map.get(session, :actions, "")],
      ["path", Map.get(session, :current_path, "")],
      ["title", Map.get(session, :title, "")],
      ["command", Map.get(session, :command, "")]
    ]

    print_table(["FIELD", "VALUE"], rows)
  end

  defp print_remote_sessions([]), do: IO.puts("no remote tmux sessions")

  defp print_remote_sessions(remote_sessions) do
    IO.puts("")

    rows =
      Enum.map(remote_sessions, fn session ->
        [
          session.server,
          session.session,
          Integer.to_string(session.attached),
          Integer.to_string(session.windows),
          truncate(session.current_path, 96)
        ]
      end)

    print_table(["REMOTE_SERVER", "REMOTE_SESSION", "ATTACHED", "WINDOWS", "PATH"], rows)
  end

  defp print_session_profiles(%{profiles: [], errors: []} = report, opts) do
    if opts[:json] do
      print_json(json_session_profiles(report))
    else
      IO.puts("no session profiles")
    end
  end

  defp print_session_profiles(report, opts) do
    if opts[:json] do
      print_json(json_session_profiles(report))
    else
      rows =
        Enum.map(report.profiles, fn profile ->
          [
            profile.ref,
            get_in(profile, [:comparison, :state]),
            get_in(profile, [:coordination, :mode]) || "",
            operator_needed_label(profile),
            get_in(profile, [:planned, :prompt_status]),
            get_in(profile, [:session, :control_mode]),
            get_in(profile, [:actual, :work_state]),
            truncate(get_in(profile, [:next_step]) || "", 36),
            truncate(get_in(profile, [:planned, :expected_completion]) || "", 32),
            truncate(get_in(profile, [:planned, :objective]) || "", 48),
            truncate(get_in(profile, [:comparison, :actual_summary]) || "", 72)
          ]
        end)

      print_table(
        [
          "REF",
          "STATE",
          "MODE",
          "OPERATOR",
          "PROMPT",
          "CONTROL",
          "WORK",
          "NEXT_STEP",
          "EXPECT",
          "OBJECTIVE",
          "ACTUAL"
        ],
        rows
      )

      IO.puts("")
      print_operator_profile(report.operator, json: false)

      IO.puts("")
      print_summary_counts("observation refresh", report.observation_refresh)

      unless report.errors == [] do
        IO.puts("")
        print_summary_errors(report.errors)
      end
    end
  end

  defp operator_needed_label(profile) do
    case get_in(profile, [:coordination, :operator_needed]) do
      true -> "needed"
      false -> "no"
      _other -> ""
    end
  end

  defp print_operator_profile(profile, opts) do
    if opts[:json] do
      print_json(%{operator: profile})
    else
      rows = [
        ["key", profile.key],
        ["source", profile.source],
        ["name", profile.name],
        ["preferences", truncate(profile.preferences, 120)],
        ["working_style", truncate(profile.working_style, 120)],
        ["escalation_policy", truncate(profile.escalation_policy, 120)],
        ["notes", truncate(profile.notes, 120)],
        ["updated_at", profile.updated_at || ""]
      ]

      print_table(["FIELD", "VALUE"], rows)
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
          [[to_string(key), "", format_bool(value)]]

        {key, value} when is_binary(value) ->
          [[to_string(key), "", value]]

        _other ->
          []
      end)

    IO.puts(name)
    print_table(["METRIC", "KEY", "VALUE"], rows)
  end

  defp summary_value(value) when is_integer(value), do: Integer.to_string(value)
  defp summary_value(value) when is_boolean(value), do: format_bool(value)
  defp summary_value(value) when is_binary(value), do: value
  defp summary_value(%_struct{} = value), do: to_string(value)
  defp summary_value(nil), do: ""
  defp summary_value(value), do: inspect(value)

  defp print_summary_errors(errors) do
    rows =
      Enum.map(errors, fn error ->
        [
          error.host,
          error.transport,
          error.subsystem,
          format_error(error.error)
        ]
      end)

    print_table(["HOST", "TRANSPORT", "SUBSYSTEM", "ERROR"], rows)
  end

  defp json_session_profiles(report) do
    %{
      generated_at: format_time(report.generated_at),
      observed: report.observed,
      observation_refresh: report.observation_refresh,
      operator: report.operator,
      total: report.total,
      profiles: report.profiles,
      errors: Enum.map(report.errors, &json_error/1)
    }
  end

  defp json_error(error) do
    %{
      host: Map.get(error, :host, ""),
      transport: Map.get(error, :transport, ""),
      subsystem: Map.get(error, :subsystem, ""),
      error: format_error(Map.get(error, :error, ""))
    }
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp format_active(true), do: "yes"
  defp format_active(false), do: "no"
  defp format_active(nil), do: "-"

  defp format_bool(true), do: "yes"
  defp format_bool(false), do: "no"

  defp format_optional_integer(nil), do: ""
  defp format_optional_integer(integer), do: Integer.to_string(integer)

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value) when is_binary(value), do: if(value == "", do: "-", else: value)

  defp truncate(value, max_length) do
    value = value || ""

    if String.length(value) > max_length do
      String.slice(value, 0, max_length - 3) <> "..."
    else
      value
    end
  end
end
