defmodule JX.CLI do
  @moduledoc """
  Command-line entrypoint for jx.
  """

  alias JX.AgentRunner
  alias JX.CiDigest
  alias JX.CLI.Actions, as: ActionsCLI
  alias JX.CLI.Agents, as: AgentsCLI
  alias JX.CLI.Approvals, as: ApprovalsCLI
  alias JX.CLI.Assignments, as: AssignmentsCLI
  alias JX.CLI.DevIDE, as: DevIDECLI
  alias JX.CLI.Fanout, as: FanoutCLI
  alias JX.CLI.Host, as: HostCLI
  alias JX.CLI.Leases, as: LeasesCLI
  alias JX.CLI.Project, as: ProjectCLI
  alias JX.CLI.Runners, as: RunnersCLI
  alias JX.CLI.Runtimes, as: RuntimesCLI
  alias JX.CLI.Session, as: SessionCLI
  alias JX.CLI.Tmux, as: TmuxCLI
  alias JX.Migrations
  alias JX.MonitorEvents
  alias JX.NextStep
  alias JX.OrchestratorDaemon
  alias JX.OrchestratorHeartbeats
  alias JX.PaneTransport
  alias JX.ProcessInventory
  alias JX.RepoDoctor
  alias JX.SSHSessions
  alias JX.Tmux
  alias JX.TUI
  alias JX.UsageModes
  alias JX.WakeTriggers
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @version Mix.Project.config()[:version]

  def main(args) do
    case run(args) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{format_error(reason)}")
        System.halt(1)
    end
  end

  def run(args) do
    {global_opts, args, invalid} =
      OptionParser.parse_head(args,
        strict: [db: :string, help: :boolean],
        aliases: [h: :help]
      )

    with :ok <- validate_options(invalid) do
      Process.put(:jx_cli_db, global_opts[:db])
      configure_db(global_opts[:db])
      dispatch(help_args(global_opts, args))
    end
  end

  defp dispatch(["init"]) do
    with :ok <- start_app(log: true) do
      IO.puts("initialized #{database_path()}")
      :ok
    end
  end

  defp dispatch(["devide" | _rest] = args), do: dispatch_devide(args)

  defp dispatch(["host" | args]), do: HostCLI.run(args, start_app: &start_app/0)

  defp dispatch(["hosts" | args]), do: HostCLI.run_plural(args, start_app: &start_app/0)

  defp dispatch(["project" | args]), do: ProjectCLI.run(args, start_app: &start_app/0)

  defp dispatch(["promote", "preflight", name | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [from: :string, to: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, promotion_preflight_usage()),
         {:ok, source_branch} <- required_option(opts, :from, promotion_preflight_usage()),
         {:ok, target_branch} <- required_option(opts, :to, promotion_preflight_usage()),
         :ok <- start_app(),
         {:ok, report} <- Workspace.promotion_preflight(name, source_branch, target_branch) do
      print_promotion_preflight(report, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["promote", "run", name | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [from: :string, to: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, promotion_run_usage()),
         {:ok, source_branch} <- required_option(opts, :from, promotion_run_usage()),
         {:ok, target_branch} <- required_option(opts, :to, promotion_run_usage()),
         :ok <- start_app(),
         {:ok, report} <- Workspace.promotion_run(name, source_branch, target_branch) do
      print_promotion(report, json: opts[:json] || false)
      promotion_cli_status(report)
    end
  end

  defp dispatch(["promote" | _args]) do
    {:error, "usage: #{promote_usage()}"}
  end

  defp dispatch(["repo", "doctor", name | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [host: :string, base: :string, promote_to: :string, json: :boolean]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, repo_doctor_usage()),
         :ok <- start_app(),
         {:ok, report} <-
           Workspace.repo_doctor(name,
             host_name: opts[:host],
             base_branch: opts[:base] || "develop",
             promote_branch: opts[:promote_to] || "master"
           ) do
      print_repo_doctor_report(report, json: opts[:json] || false)

      if RepoDoctor.passed?(report) do
        :ok
      else
        {:error, "repo doctor checks failed"}
      end
    end
  end

  defp dispatch(["repo", "gate", name | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [host: :string, base: :string, promote_to: :string, json: :boolean]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, repo_gate_usage()),
         :ok <- start_app(),
         {:ok, report} <-
           Workspace.repo_gate(name,
             host_name: opts[:host],
             base_branch: opts[:base] || "develop",
             promote_branch: opts[:promote_to] || "master"
           ) do
      print_repo_gate_report(report, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["repo" | _args]) do
    {:error, "usage: #{repo_usage()}"}
  end

  defp dispatch(["ci", "digest", pr_number | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [repo: :string, logs: :boolean, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, ci_digest_usage()),
         {:ok, pr_number} <- parse_positive_integer(pr_number, "pr"),
         {:ok, repo} <- required_option(opts, :repo, ci_digest_usage()),
         {:ok, digest} <- CiDigest.run(repo, pr_number, logs: Keyword.get(opts, :logs, true)) do
      print_ci_digest(digest, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["ci", "watch", pr_number | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          repo: :string,
          ref: :string,
          project: :string,
          mode: :string,
          goal: :string,
          head_sha: :string,
          pass_prompt: :string,
          fail_prompt: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, ci_watch_usage()),
         {:ok, pr_number} <- parse_positive_integer(pr_number, "pr"),
         {:ok, repo} <- required_option(opts, :repo, ci_watch_usage()),
         :ok <- validate_optional_ci_watch_mode(opts[:mode]),
         :ok <- start_app(),
         {:ok, watch} <-
           Workspace.add_ci_watch(%{
             repo: repo,
             pr_number: pr_number,
             ref: opts[:ref] || "",
             project: opts[:project] || "",
             mode: opts[:mode] || "notify",
             goal: opts[:goal] || "",
             head_sha: opts[:head_sha] || "",
             success_prompt: opts[:pass_prompt] || "",
             failure_prompt: opts[:fail_prompt] || ""
           }) do
      print_ci_watch(watch, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["ci", "watches" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          status: :string,
          repo: :string,
          ref: :string,
          project: :string,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, ci_watches_usage()),
         :ok <- validate_optional_ci_watch_status(opts[:status]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_ci_watches(
        status: opts[:status],
        repo: opts[:repo],
        ref: opts[:ref],
        project: opts[:project],
        limit: limit
      )
      |> print_ci_watches(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["ci", "review", watch_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [logs: :boolean, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, ci_review_usage()),
         :ok <- start_app(),
         {:ok, review} <-
           Workspace.review_ci_watch(watch_id, logs: Keyword.get(opts, :logs, true)) do
      print_ci_watch_review(review, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["ci", "cancel", watch_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [summary: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, ci_cancel_usage()),
         :ok <- start_app(),
         {:ok, watch} <- Workspace.cancel_ci_watch(watch_id, opts[:summary] || "manual cancel") do
      print_ci_watch(watch, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["ci" | _args]), do: {:error, "usage: #{ci_usage()}"}

  defp dispatch(["portfolio", "summary" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          project: :string,
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

    lines = opts[:lines] || 80
    limit = opts[:n] || 25
    scan_limit = opts[:scan_limit] || max(limit * 5, 100)

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             portfolio_summary_usage()
           ),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_optional_work_board_control(opts[:control]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(),
         {:ok, summary} <-
           Workspace.portfolio_summary(
             host_name: opts[:host],
             project: opts[:project],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             ssh_target: opts[:ssh_target],
             work_state: opts[:work_state],
             control_mode: opts[:control],
             observe: Keyword.get(opts, :observe, true),
             lines: lines,
             scan_limit: scan_limit,
             limit: limit
           ) do
      print_portfolio_summary(summary, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["portfolio" | _args]), do: {:error, "usage: #{portfolio_summary_usage()}"}

  defp dispatch(["call", "brief" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          project: :string,
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

    lines = opts[:lines] || 80
    limit = opts[:n] || 5
    scan_limit = opts[:scan_limit] || max(limit * 5, 100)

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, call_brief_usage()),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_optional_work_board_control(opts[:control]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(),
         {:ok, brief} <-
           Workspace.call_brief(
             host_name: opts[:host],
             project: opts[:project],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             ssh_target: opts[:ssh_target],
             work_state: opts[:work_state],
             control_mode: opts[:control],
             observe: Keyword.get(opts, :observe, false),
             lines: lines,
             scan_limit: scan_limit,
             limit: limit
           ) do
      print_call_brief(brief, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["call", "handoff", "add" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          summary: :string,
          title: :string,
          surface: :string,
          project: :string,
          ref: :string,
          operator_input: :string,
          decision: :string,
          follow_up: :string,
          brief: :boolean,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, call_handoff_add_usage()),
         {:ok, summary} <- required_option(opts, :summary, call_handoff_add_usage()),
         :ok <- validate_optional_call_surface(opts[:surface]),
         :ok <- start_app(),
         {:ok, handoff} <-
           Workspace.create_call_handoff(
             %{
               summary: summary,
               title: opts[:title] || "",
               surface: opts[:surface] || "call",
               project: opts[:project] || "",
               ref: opts[:ref] || "",
               operator_input: opts[:operator_input] || "",
               decisions: Keyword.get_values(opts, :decision),
               follow_ups: Keyword.get_values(opts, :follow_up)
             },
             brief: Keyword.get(opts, :brief, true)
           ) do
      print_call_handoff(handoff, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["call", "handoff", "ls" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          status: :string,
          surface: :string,
          project: :string,
          ref: :string,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, call_handoff_ls_usage()),
         :ok <- validate_optional_call_handoff_status(opts[:status]),
         :ok <- validate_optional_call_surface(opts[:surface]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_call_handoffs(
        status: opts[:status],
        surface: opts[:surface],
        project: opts[:project],
        ref: opts[:ref],
        limit: limit
      )
      |> print_call_handoffs(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["call", "handoff", "close", handoff_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [summary: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, call_handoff_close_usage()),
         :ok <- start_app(),
         {:ok, handoff} <- Workspace.close_call_handoff(handoff_id, opts[:summary] || "") do
      print_call_handoff(handoff, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["call", "handoff", "apply", handoff_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          action: :string,
          ref: :string,
          message: :string,
          prompt_status: :string,
          ready: :boolean,
          draft: :boolean,
          reason: :string,
          goal: :string,
          success: :string,
          blocker: :string,
          mode: :string,
          prompt: :string,
          summary: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, call_handoff_apply_usage()),
         :ok <- validate_optional_call_handoff_apply_action(opts[:action]),
         :ok <- validate_call_handoff_apply_prompt_status(opts),
         :ok <- validate_optional_watch_mode(opts[:mode]),
         {:ok, apply_attrs} <- call_handoff_apply_attrs(opts),
         :ok <- start_app(),
         {:ok, result} <- Workspace.apply_call_handoff(handoff_id, apply_attrs) do
      print_call_handoff_apply(result, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["call", "handoff" | _args]), do: {:error, "usage: #{call_handoff_usage()}"}
  defp dispatch(["call" | _args]), do: {:error, "usage: #{call_usage()}"}

  defp dispatch(["next" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          project: :string,
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

    lines = opts[:lines] || 80
    limit = opts[:n] || 5
    scan_limit = opts[:scan_limit] || max(limit * 5, 100)

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, next_usage()),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_optional_work_board_control(opts[:control]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(),
         {:ok, brief} <-
           Workspace.call_brief(
             host_name: opts[:host],
             project: opts[:project],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             ssh_target: opts[:ssh_target],
             work_state: opts[:work_state],
             control_mode: opts[:control],
             observe: Keyword.get(opts, :observe, true),
             lines: lines,
             scan_limit: scan_limit,
             limit: limit
           ) do
      brief
      |> NextStep.build()
      |> print_next_step(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["tui", "plan" | args]), do: dispatch_tui_plan(args)
  defp dispatch(["tui", "interactive" | args]), do: dispatch_tui_snapshot(args, interactive: true)
  defp dispatch(["tui", "snapshot" | args]), do: dispatch_tui_snapshot(args, interactive: false)
  defp dispatch(["tui", "watch" | args]), do: dispatch_tui_snapshot(args, watch: true)
  defp dispatch(["tui", "panel" | args]), do: dispatch_tui_snapshot(args, watch: false)
  defp dispatch(["tui" | args]), do: dispatch_tui_snapshot(args, interactive: :default)

  defp dispatch(["wake" | args]) do
    dispatch_wake(args)
  end

  defp dispatch(["meet", "plugin" | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, meet_plugin_usage()),
         :ok <- start_app() do
      Workspace.participant_plugins()
      |> Enum.find(&(&1.id == "google_meet"))
      |> print_meet_plugin(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["meet", "auth", "configure" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          profile: :string,
          email: :string,
          client_id: :string,
          client_secret_env: :string,
          redirect_uri: :string,
          scope: :keep,
          artifacts: :boolean,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, meet_auth_configure_usage()),
         {:ok, client_id} <- required_option(opts, :client_id, meet_auth_configure_usage()),
         :ok <- start_app(),
         {:ok, profile} <-
           Workspace.google_meet_configure_auth(%{
             profile: opts[:profile] || "personal",
             email: opts[:email] || "",
             client_id: client_id,
             client_secret_env: opts[:client_secret_env] || "GOOGLE_OAUTH_CLIENT_SECRET",
             redirect_uri: opts[:redirect_uri] || "http://127.0.0.1:8765/oauth2/callback",
             scopes: Keyword.get_values(opts, :scope),
             artifacts: opts[:artifacts] || false
           }) do
      profile
      |> JX.GoogleMeet.auth_profile_summary()
      |> print_meet_auth_profile(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["meet", "auth", "url" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [profile: :string, login_hint: :string, scope: :keep, json: :boolean]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, meet_auth_url_usage()),
         :ok <- start_app(),
         {:ok, packet} <-
           Workspace.google_meet_auth_url(opts[:profile] || "personal",
             login_hint: opts[:login_hint],
             scopes: optional_repeated(opts, :scope)
           ) do
      print_meet_auth_url(packet, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["meet", "auth", "exchange" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [profile: :string, code: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, meet_auth_exchange_usage()),
         {:ok, code} <- required_option(opts, :code, meet_auth_exchange_usage()),
         :ok <- start_app(),
         {:ok, profile} <-
           Workspace.google_meet_exchange_auth_code(opts[:profile] || "personal", code) do
      print_meet_auth_profile(profile, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["meet", "auth", "status" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [profile: :string, n: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = opts[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, meet_auth_status_usage()),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      profiles =
        Workspace.google_meet_auth_profiles(limit: limit)
        |> Enum.map(&JX.GoogleMeet.auth_profile_summary/1)
        |> maybe_filter_profile(opts[:profile])

      print_meet_auth_profiles(profiles, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["meet", "auth" | _args]), do: {:error, "usage: #{meet_auth_usage()}"}

  defp dispatch(["meet", "session", "create" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          meeting: :string,
          title: :string,
          project: :string,
          ref: :string,
          auth_profile: :string,
          chrome_node: :string,
          paired_chrome_node: :string,
          twilio_stream_url: :string,
          twilio_mode: :string,
          twilio_track: :string,
          twilio_call_sid: :string,
          websocket_url: :string,
          artifact_dir: :string,
          conference_record: :string,
          handoff: :boolean,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, meet_session_create_usage()),
         :ok <- validate_optional_meet_twilio_mode(opts[:twilio_mode]),
         :ok <- validate_optional_meet_twilio_track(opts[:twilio_track]),
         :ok <- start_app(),
         {:ok, session} <-
           Workspace.google_meet_create_session(
             meet_session_attrs(opts),
             handoff: Keyword.get(opts, :handoff, true)
           ) do
      print_meet_session(session, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["meet", "session", "ls" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          status: :string,
          project: :string,
          ref: :string,
          meeting: :string,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, meet_session_ls_usage()),
         :ok <- validate_optional_meet_session_status(opts[:status]),
         :ok <- validate_positive("n", limit),
         {:ok, meeting_code} <- optional_meeting_code(opts[:meeting]),
         :ok <- start_app() do
      Workspace.google_meet_sessions(
        status: opts[:status],
        project: opts[:project],
        ref: opts[:ref],
        meeting_code: meeting_code,
        limit: limit
      )
      |> print_meet_sessions(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["meet", "session", "plan", session_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, meet_session_plan_usage()),
         :ok <- start_app(),
         {:ok, plan} <- Workspace.google_meet_join_plan(session_id) do
      print_meet_plan(plan, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["meet", "session", "join", session_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          runner: :string,
          browser_agent_command: :string,
          debug_url: :string,
          launch: :boolean,
          chrome_bin: :string,
          profile_dir: :string,
          paired_profile_dir: :string,
          paired: :boolean,
          paired_click_join: :boolean,
          click: :boolean,
          mute: :boolean,
          camera_off: :boolean,
          timeout_ms: :integer,
          settle_ms: :integer,
          poll_ms: :integer,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, meet_session_join_usage()),
         :ok <- validate_optional_meet_join_runner(opts[:runner]),
         :ok <- validate_optional_positive("timeout-ms", opts[:timeout_ms]),
         :ok <- validate_optional_non_negative("settle-ms", opts[:settle_ms]),
         :ok <- validate_optional_positive("poll-ms", opts[:poll_ms]),
         :ok <- start_app(),
         {:ok, result} <- Workspace.google_meet_join_session(session_id, meet_join_opts(opts)) do
      print_meet_join(result, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["meet", "session" | _args]), do: {:error, "usage: #{meet_session_usage()}"}

  defp dispatch(["meet", "realtime", "plan", session_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          provider: :string,
          audio_bridge: :string,
          browser_agent_command: :string,
          audio_ingress_command: :string,
          audio_egress_command: :string,
          approve_audio_capture: :boolean,
          approve_speech_output: :boolean,
          approve_notes_or_transcription: :boolean,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, meet_realtime_plan_usage()),
         :ok <- validate_optional_meet_realtime_provider(opts[:provider]),
         :ok <- validate_optional_meet_audio_bridge(opts[:audio_bridge]),
         :ok <- start_app(),
         {:ok, plan} <- Workspace.google_meet_realtime_plan(session_id, meet_realtime_opts(opts)) do
      print_meet_realtime_plan(plan, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["meet", "realtime", "start", session_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          provider: :string,
          audio_bridge: :string,
          browser_agent_command: :string,
          audio_ingress_command: :string,
          audio_egress_command: :string,
          approve_audio_capture: :boolean,
          approve_speech_output: :boolean,
          approve_notes_or_transcription: :boolean,
          live: :boolean,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, meet_realtime_start_usage()),
         :ok <- validate_optional_meet_realtime_provider(opts[:provider]),
         :ok <- validate_optional_meet_audio_bridge(opts[:audio_bridge]),
         :ok <- start_app(),
         {:ok, result} <-
           Workspace.google_meet_start_realtime(
             session_id,
             meet_realtime_attrs(opts),
             meet_realtime_opts(opts)
           ) do
      print_meet_realtime_start(result, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["meet", "realtime", "watch", session_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          browser_agent_command: :string,
          caption_file: :string,
          chat_file: :string,
          consult_command: :string,
          speech_output_command: :string,
          iterations: :integer,
          interval_ms: :integer,
          min_chars: :integer,
          timeout_ms: :integer,
          speak: :boolean,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, meet_realtime_watch_usage()),
         :ok <- validate_optional_non_negative("iterations", opts[:iterations]),
         :ok <- validate_optional_non_negative("interval-ms", opts[:interval_ms]),
         :ok <- validate_optional_positive("min-chars", opts[:min_chars]),
         :ok <- validate_optional_positive("timeout-ms", opts[:timeout_ms]),
         :ok <- start_app(),
         {:ok, result} <-
           Workspace.google_meet_realtime_watch(session_id, meet_realtime_watch_opts(opts)) do
      print_meet_realtime_watch(result, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["meet", "realtime", "consult", session_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          transcript: :string,
          summary: :string,
          title: :string,
          operator_input: :string,
          decision: :keep,
          follow_up: :keep,
          project: :string,
          ref: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, meet_realtime_consult_usage()),
         {:ok, transcript} <- required_option(opts, :transcript, meet_realtime_consult_usage()),
         :ok <- start_app(),
         {:ok, result} <-
           Workspace.google_meet_realtime_consult(
             session_id,
             meet_realtime_consult_attrs(Keyword.put(opts, :transcript, transcript)),
             project: opts[:project],
             ref: opts[:ref]
           ) do
      print_meet_realtime_consult(result, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["meet", "realtime" | _args]), do: {:error, "usage: #{meet_realtime_usage()}"}

  defp dispatch(["meet", "recover" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          debug_url: :string,
          paired_debug_url: :string,
          targets_json: :string,
          paired_targets_json: :string,
          meeting: :string,
          title: :string,
          project: :string,
          ref: :string,
          auth_profile: :string,
          twilio_stream_url: :string,
          twilio_mode: :string,
          twilio_track: :string,
          artifact_dir: :string,
          handoff: :boolean,
          dry_run: :boolean,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, meet_recover_usage()),
         :ok <- validate_meet_recover_source(opts),
         :ok <- validate_optional_meet_twilio_mode(opts[:twilio_mode]),
         :ok <- validate_optional_meet_twilio_track(opts[:twilio_track]),
         :ok <- start_app(),
         {:ok, recovery} <-
           Workspace.google_meet_recover_open_tabs(meet_recover_attrs(opts)) do
      print_meet_recovery(recovery, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["meet", "sync", session_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, meet_sync_usage()),
         :ok <- start_app(),
         {:ok, session} <- Workspace.google_meet_sync_artifacts(session_id) do
      print_meet_session_packet(session, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["meet", "export", session_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [dir: :string, format: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, meet_export_usage()),
         :ok <- validate_optional_meet_export_format(opts[:format]),
         :ok <- start_app(),
         {:ok, export} <-
           Workspace.google_meet_export_session(session_id,
             dir: opts[:dir],
             format: opts[:format] || "all"
           ) do
      print_meet_export(export, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["meet" | _args]), do: {:error, "usage: #{meet_usage()}"}

  defp dispatch(["delegate", "create" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          title: :string,
          brief: :string,
          project: :string,
          ref: :string,
          owner: :string,
          agent: :string,
          priority: :integer,
          context: :keep,
          constraint: :keep,
          acceptance: :keep,
          verify: :keep,
          write: :keep,
          forbid: :keep,
          json: :boolean
        ]
      )

    priority = opts[:priority] || 0

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, delegate_create_usage()),
         {:ok, title} <- required_option(opts, :title, delegate_create_usage()),
         {:ok, brief} <- required_option(opts, :brief, delegate_create_usage()),
         :ok <- validate_non_negative("priority", priority),
         :ok <- validate_optional_delegation_agent(opts[:agent]),
         :ok <- start_app(),
         {:ok, delegation} <-
           Workspace.create_delegation(%{
             title: title,
             brief: brief,
             project: opts[:project] || "",
             ref: opts[:ref] || "",
             owner: opts[:owner] || "",
             agent_kind: opts[:agent] || "worker",
             priority: priority,
             context: Keyword.get_values(opts, :context),
             constraints: Keyword.get_values(opts, :constraint),
             acceptance: Keyword.get_values(opts, :acceptance),
             verification: Keyword.get_values(opts, :verify),
             write_paths: Keyword.get_values(opts, :write),
             forbidden_paths: Keyword.get_values(opts, :forbid)
           }) do
      print_delegation(delegation, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["delegate", "ls" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          status: :string,
          project: :string,
          ref: :string,
          owner: :string,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, delegate_ls_usage()),
         :ok <- validate_optional_delegation_status(opts[:status]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_delegations(
        status: opts[:status],
        project: opts[:project],
        ref: opts[:ref],
        owner: opts[:owner],
        limit: limit
      )
      |> print_delegations(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["delegate", "reviews" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          project: :string,
          ref: :string,
          integration: :string,
          decision: :string,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, delegate_reviews_usage()),
         :ok <- validate_optional_integration_status(opts[:integration]),
         :ok <- validate_optional_review_decision(opts[:decision]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.delegation_reviews(
        project: opts[:project],
        ref: opts[:ref],
        integration_status: opts[:integration] || "pending",
        decision: opts[:decision],
        limit: limit
      )
      |> print_delegation_reviews(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["delegate", "timing" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          project: :string,
          ref: :string,
          agent: :string,
          target_parallel: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, delegate_timing_usage()),
         :ok <- validate_optional_delegation_agent(opts[:agent]),
         :ok <- validate_positive("target-parallel", opts[:target_parallel] || 3),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.delegation_timing(
        project: opts[:project],
        ref: opts[:ref],
        agent_kind: opts[:agent],
        target_parallel: opts[:target_parallel] || 3,
        limit: limit
      )
      |> print_delegation_timing(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["delegate", "brief", delegation_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, delegate_brief_usage()),
         :ok <- start_app(),
         {:ok, brief} <- Workspace.delegation_brief(delegation_id) do
      if opts[:json],
        do: print_json(%{delegation_id: delegation_id, brief: brief}),
        else: IO.puts(brief)

      :ok
    end
  end

  defp dispatch(["delegate", "lint", delegation_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, delegate_lint_usage()),
         :ok <- start_app(),
         {:ok, report} <- Workspace.delegation_preflight(delegation_id) do
      print_delegation_preflight(report, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["delegate", "review", delegation_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, delegate_review_usage()),
         :ok <- start_app(),
         {:ok, review} <- Workspace.delegation_review(delegation_id) do
      print_delegation_review(review, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["delegate", "decide", delegation_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [decision: :string, summary: :string, reviewer: :string, json: :boolean]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, delegate_decide_usage()),
         {:ok, decision} <- required_option(opts, :decision, delegate_decide_usage()),
         :ok <- validate_review_decision(decision),
         :ok <- start_app(),
         {:ok, delegation} <-
           Workspace.decide_delegation_review(delegation_id, decision,
             summary: opts[:summary] || "",
             reviewer: opts[:reviewer] || ""
           ) do
      print_delegation(delegation, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["delegate", "evidence", delegation_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          command: :string,
          cwd: :string,
          exit: :integer,
          kind: :string,
          output: :string,
          artifact: :keep,
          risk: :keep,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, delegate_evidence_usage()),
         {:ok, evidence_attrs} <- evidence_attrs(opts, delegate_evidence_usage()),
         :ok <- start_app(),
         {:ok, delegation} <- Workspace.add_delegation_evidence(delegation_id, evidence_attrs) do
      print_delegation(delegation, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["delegate", "start", delegation_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [owner: :string, summary: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, delegate_start_usage()),
         :ok <- start_app(),
         {:ok, delegation} <-
           Workspace.start_delegation(delegation_id,
             owner: opts[:owner] || "",
             worker_summary: opts[:summary] || ""
           ) do
      print_delegation(delegation, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["delegate", "complete", delegation_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          summary: :string,
          verify: :keep,
          artifact: :keep,
          risk: :keep,
          evidence_command: :string,
          evidence_cwd: :string,
          evidence_exit: :integer,
          evidence_kind: :string,
          evidence_output: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, delegate_complete_usage()),
         {:ok, evidence} <- complete_evidence(opts),
         :ok <- start_app(),
         {:ok, delegation} <-
           Workspace.complete_delegation(delegation_id, complete_delegation_attrs(opts, evidence)) do
      print_delegation(delegation, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["delegate", "block", delegation_id | args]) do
    dispatch_delegate_terminal(delegation_id, args, "block")
  end

  defp dispatch(["delegate", "fail", delegation_id | args]) do
    dispatch_delegate_terminal(delegation_id, args, "fail")
  end

  defp dispatch(["delegate", "cancel", delegation_id | args]) do
    dispatch_delegate_terminal(delegation_id, args, "cancel")
  end

  defp dispatch(["delegate" | _args]), do: {:error, "usage: #{delegate_usage()}"}

  defp dispatch(["fanout" | args]), do: FanoutCLI.run(args, start_app: &start_app/0)

  defp dispatch(["assign", project_name | args]) do
    {opts, prompt_parts, invalid} =
      OptionParser.parse(args,
        strict: [
          agent: :string,
          transport: :string,
          host: :string,
          goal: :boolean,
          goal_objective: :string
        ]
      )

    agent_name = opts[:agent] || "claude"
    agent_transport = opts[:transport] || AgentRunner.default_agent_transport()
    goal_objective = opts[:goal_objective] || ""

    with :ok <- validate_options(invalid),
         :ok <- validate_agent_name(agent_name),
         :ok <- validate_agent_transport(agent_transport),
         prompt when prompt != "" <- Enum.join(prompt_parts, " ") |> String.trim(),
         :ok <- start_app(),
         {:ok, task} <-
           Workspace.assign_task(project_name, prompt,
             agent_name: agent_name,
             agent_transport: agent_transport,
             host_name: opts[:host],
             goal: opts[:goal] || goal_objective != "",
             goal_objective: goal_objective
           ) do
      goal_line = assign_goal_line(task)

      IO.puts("""
      task #{task.task_id} assigned
      host: #{task.host.name}
      transport: #{task.agent_transport}
      #{goal_line}\
      branch: #{task.branch}
      worktree: #{task.worktree_path}
      session: #{task.session_name}
      log: #{task.log_path}
      launch: #{task.launch_command}
      """)

      :ok
    else
      "" ->
        {:error,
         "usage: jx assign <project> \"<task prompt>\" [--host <host>] [--agent claude|opencode|codex] [--transport native|acpx] [--goal] [--goal-objective <objective>]"}

      other ->
        other
    end
  end

  defp dispatch(["status"]) do
    with :ok <- start_app() do
      Workspace.list_statuses()
      |> print_statuses()

      :ok
    end
  end

  defp dispatch(["operate" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          project: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          target: :string,
          observe: :boolean,
          execute: :string,
          yes: :boolean,
          lines: :integer,
          stale_seconds: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 20
    lines = opts[:lines] || 40
    stale_after_seconds = opts[:stale_seconds] || 300

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx operate [--observe] [--execute safe|rec-id] [--yes] [--host <host>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--target <ssh-target>] [--lines 40] [--stale-seconds 300] [-n 20] [--json]"
           ),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("stale-seconds", stale_after_seconds),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(),
         {:ok, operation} <-
           Workspace.operate(
             host_name: opts[:host],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             ssh_target: opts[:ssh_target],
             target: opts[:target],
             observe: opts[:observe] || true,
             execute: opts[:execute],
             yes: opts[:yes] || false,
             lines: lines,
             stale_after_seconds: stale_after_seconds,
             limit: limit
           ) do
      print_operation(operation, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["manage" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          policy: :string,
          iterations: :integer,
          sleep_ms: :integer,
          host: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          target: :string,
          lines: :integer,
          stale_seconds: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    policy = opts[:policy] || "conservative"
    iterations = opts[:iterations] || 1
    sleep_ms = opts[:sleep_ms] || 0
    lines = opts[:lines] || 40
    stale_after_seconds = opts[:stale_seconds] || 300
    limit = opts[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx manage [--policy conservative] [--iterations 1] [--sleep-ms 0] [--host <host>] [--type <type>] [--json]"
           ),
         :ok <- validate_manage_policy(policy),
         :ok <- validate_positive("iterations", iterations),
         :ok <- validate_non_negative("sleep-ms", sleep_ms),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("stale-seconds", stale_after_seconds),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(),
         {:ok, report} <-
           Workspace.manage(
             policy: policy,
             iterations: iterations,
             sleep_ms: sleep_ms,
             host_name: opts[:host],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             ssh_target: opts[:ssh_target],
             target: opts[:target],
             lines: lines,
             stale_after_seconds: stale_after_seconds,
             limit: limit
           ) do
      print_manage_report(report, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["orchestrator", "start" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          session: :string,
          server: :string,
          log: :string,
          replace: :boolean,
          dry_run: :boolean,
          consumer: :string,
          host: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          work_state: :string,
          control: :string,
          prompt_status: :string,
          observe: :boolean,
          lines: :integer,
          scan_limit: :integer,
          queue_limit: :integer,
          event_limit: :integer,
          decision_limit: :integer,
          min_observe_age_seconds: :integer,
          interval_ms: :integer,
          execute: :boolean,
          yes: :boolean,
          ack: :boolean,
          auto_plan: :boolean,
          no_enter: :boolean,
          json: :boolean
        ]
      )

    lines = opts[:lines] || 160
    scan_limit = opts[:scan_limit] || 100
    queue_limit = opts[:queue_limit] || 10
    event_limit = opts[:event_limit] || 50
    decision_limit = opts[:decision_limit] || 20
    min_observe_age_seconds = opts[:min_observe_age_seconds] || 15
    interval_ms = opts[:interval_ms] || 15_000
    server = opts[:server] || Tmux.managed_server()

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, orchestrator_usage()),
         :ok <- validate_tmux_server(server),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_optional_work_board_control(opts[:control]),
         :ok <- validate_optional_prompt_status(opts[:prompt_status]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("queue-limit", queue_limit),
         :ok <- validate_positive("event-limit", event_limit),
         :ok <- validate_positive("decision-limit", decision_limit),
         :ok <- validate_non_negative("min-observe-age-seconds", min_observe_age_seconds),
         :ok <- validate_positive("interval-ms", interval_ms),
         :ok <- start_app(),
         {:ok, status} <-
           OrchestratorDaemon.start(
             orchestrator_daemon_opts(opts,
               server: server,
               lines: lines,
               scan_limit: scan_limit,
               queue_limit: queue_limit,
               event_limit: event_limit,
               decision_limit: decision_limit,
               min_observe_age_seconds: min_observe_age_seconds,
               interval_ms: interval_ms,
               db_path: database_path()
             )
           ) do
      print_orchestrator_daemon_status(status, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["orchestrator", "status" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [session: :string, server: :string, log: :string, json: :boolean]
      )

    server = opts[:server] || Tmux.managed_server()

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, orchestrator_usage()),
         :ok <- validate_tmux_server(server),
         {:ok, status} <-
           OrchestratorDaemon.status(orchestrator_daemon_opts(opts, server: server)) do
      print_orchestrator_daemon_status(status, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["orchestrator", "stop" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [session: :string, server: :string, log: :string, json: :boolean]
      )

    server = opts[:server] || Tmux.managed_server()

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, orchestrator_usage()),
         :ok <- validate_tmux_server(server),
         {:ok, status} <- OrchestratorDaemon.stop(orchestrator_daemon_opts(opts, server: server)) do
      print_orchestrator_daemon_status(status, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["orchestrator", "logs" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [session: :string, server: :string, log: :string, n: :integer, json: :boolean],
        aliases: [n: :n]
      )

    lines = opts[:n] || 80
    server = opts[:server] || Tmux.managed_server()

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, orchestrator_usage()),
         :ok <- validate_tmux_server(server),
         :ok <- validate_positive("n", lines),
         {:ok, log} <-
           OrchestratorDaemon.logs(orchestrator_daemon_opts(opts, server: server, lines: lines)) do
      if opts[:json] do
        print_json(log)
      else
        IO.write(log.output)
        if log.output != "" and not String.ends_with?(log.output, "\n"), do: IO.puts("")
      end

      :ok
    end
  end

  defp dispatch(["orchestrator", "heartbeats" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [consumer: :string, status: :string, n: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = opts[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx orchestrator heartbeats [--consumer <name>] [--status running|idle|error|stopped] [-n 20] [--json]"
           ),
         :ok <- validate_optional_heartbeat_status(opts[:status]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_orchestrator_heartbeats(
        consumer: opts[:consumer],
        status: opts[:status],
        limit: limit
      )
      |> print_orchestrator_heartbeats(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["orchestrator", "health" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          consumer: :string,
          status: :string,
          stale_after_seconds: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 20
    stale_after_seconds = opts[:stale_after_seconds] || 120

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx orchestrator health [--consumer <name>] [--status running|idle|error|stopped] [--stale-after-seconds 120] [-n 20] [--json]"
           ),
         :ok <- validate_optional_heartbeat_status(opts[:status]),
         :ok <- validate_positive("stale-after-seconds", stale_after_seconds),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.orchestrator_health(
        consumer: opts[:consumer],
        status: opts[:status],
        stale_after_seconds: stale_after_seconds,
        limit: limit
      )
      |> print_orchestrator_health(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["orchestrator", "inbox" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          project: :string,
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

    lines = opts[:lines] || 160
    limit = opts[:n] || 20
    scan_limit = opts[:scan_limit] || 100

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, orchestrator_usage()),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_optional_work_board_control(opts[:control]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(),
         {:ok, inbox} <-
           Workspace.orchestrator_inbox(
             host_name: opts[:host],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             ssh_target: opts[:ssh_target],
             work_state: opts[:work_state],
             control_mode: opts[:control],
             observe: Keyword.get(opts, :observe, true),
             lines: lines,
             scan_limit: scan_limit,
             limit: limit
           ) do
      print_orchestrator_inbox(inbox, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["orchestrator", "review", ref | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          observe: :boolean,
          lines: :integer,
          json: :boolean
        ]
      )

    lines = opts[:lines] || 220

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, orchestrator_usage()),
         :ok <- validate_positive("lines", lines),
         :ok <- start_app(),
         {:ok, review} <-
           Workspace.orchestrator_review(ref,
             observe: Keyword.get(opts, :observe, true),
             lines: lines
           ) do
      print_orchestrator_review(review, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["orchestrator", "decide", ref | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          prompt: :string,
          ready: :boolean,
          draft: :boolean,
          hold: :string,
          clear: :boolean,
          ignore: :boolean,
          protect: :boolean,
          managed: :boolean,
          note: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, orchestrator_usage()),
         {:ok, attrs} <- orchestrator_decide_attrs(opts),
         :ok <- start_app(),
         {:ok, result} <- Workspace.orchestrator_decide(ref, attrs) do
      print_orchestrator_decision(result, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["orchestrator" | _args]), do: {:error, "usage: #{orchestrator_usage()}"}

  defp dispatch(["orchestrate", command | args]) when command in ["step", "run", "start"] do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          consumer: :string,
          host: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          work_state: :string,
          control: :string,
          prompt_status: :string,
          observe: :boolean,
          lines: :integer,
          scan_limit: :integer,
          queue_limit: :integer,
          event_limit: :integer,
          decision_limit: :integer,
          min_observe_age_seconds: :integer,
          interval_ms: :integer,
          iterations: :integer,
          execute: :boolean,
          yes: :boolean,
          ack: :boolean,
          auto_plan: :boolean,
          no_enter: :boolean,
          json: :boolean
        ]
      )

    lines = opts[:lines] || 40
    scan_limit = opts[:scan_limit] || 100
    queue_limit = opts[:queue_limit] || 5
    event_limit = opts[:event_limit] || 50
    decision_limit = opts[:decision_limit] || 20
    min_observe_age_seconds = opts[:min_observe_age_seconds] || 30
    interval_ms = opts[:interval_ms] || 30_000
    iterations = opts[:iterations] || if(command == "step", do: 1, else: 0)

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, orchestrate_usage()),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_optional_work_board_control(opts[:control]),
         :ok <- validate_optional_prompt_status(opts[:prompt_status]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("queue-limit", queue_limit),
         :ok <- validate_positive("event-limit", event_limit),
         :ok <- validate_positive("decision-limit", decision_limit),
         :ok <- validate_non_negative("min-observe-age-seconds", min_observe_age_seconds),
         :ok <- validate_positive("interval-ms", interval_ms),
         :ok <- validate_non_negative("iterations", iterations),
         :ok <- start_app() do
      orchestrate_opts =
        [
          consumer: opts[:consumer],
          host_name: opts[:host],
          all_tmux: !opts[:managed],
          all_processes: opts[:all_processes] || false,
          type: opts[:type],
          ssh_target: opts[:ssh_target],
          work_state: opts[:work_state],
          control_mode: opts[:control],
          prompt_status: opts[:prompt_status],
          observe: Keyword.get(opts, :observe, true),
          lines: lines,
          limit: scan_limit,
          queue_limit: queue_limit,
          event_limit: event_limit,
          decision_limit: decision_limit,
          min_observe_age_seconds: min_observe_age_seconds,
          interval_ms: interval_ms,
          execute: opts[:execute] || false,
          yes: opts[:yes] || false,
          auto_plan: opts[:auto_plan] || false,
          enter: !opts[:no_enter]
        ]
        |> maybe_put(:ack, opts[:ack])

      run_orchestrate(command, orchestrate_opts, iterations, interval_ms,
        json: opts[:json] || false
      )
    end
  end

  defp dispatch(["orchestrate" | _args]), do: {:error, "usage: #{orchestrate_usage()}"}

  defp dispatch(["monitor", command | args]) when command in ["scan", "run", "start"] do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          project: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          work_state: :string,
          control: :string,
          prompt_status: :string,
          observe: :boolean,
          lines: :integer,
          scan_limit: :integer,
          queue_limit: :integer,
          event_limit: :integer,
          interval_ms: :integer,
          iterations: :integer,
          json: :boolean
        ]
      )

    lines = opts[:lines] || 40
    scan_limit = opts[:scan_limit] || 100
    queue_limit = opts[:queue_limit] || 5
    event_limit = opts[:event_limit] || 20
    interval_ms = opts[:interval_ms] || 30_000
    iterations = opts[:iterations] || if(command == "scan", do: 1, else: 0)

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, monitor_usage()),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_optional_work_board_control(opts[:control]),
         :ok <- validate_optional_prompt_status(opts[:prompt_status]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("queue-limit", queue_limit),
         :ok <- validate_positive("event-limit", event_limit),
         :ok <- validate_positive("interval-ms", interval_ms),
         :ok <- validate_non_negative("iterations", iterations),
         :ok <- start_app() do
      monitor_opts = [
        host_name: opts[:host],
        all_tmux: !opts[:managed],
        all_processes: opts[:all_processes] || false,
        type: opts[:type],
        ssh_target: opts[:ssh_target],
        work_state: opts[:work_state],
        control_mode: opts[:control],
        prompt_status: opts[:prompt_status],
        observe: Keyword.get(opts, :observe, true),
        lines: lines,
        limit: scan_limit,
        queue_limit: queue_limit,
        event_limit: event_limit
      ]

      run_monitor(command, monitor_opts, iterations, interval_ms, json: opts[:json] || false)
    end
  end

  defp dispatch(["monitor", "status" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [consumer: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx monitor status [--consumer <name>] [--json]"),
         :ok <- start_app() do
      Workspace.monitor_event_status(consumer: opts[:consumer])
      |> print_monitor_event_status(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["monitor" | _args]), do: {:error, "usage: #{monitor_usage()}"}

  defp dispatch(["events", "check" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [n: :integer, json: :boolean], aliases: [n: :n])

    limit = opts[:n] || 10_000

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx events check [-n 10000] [--json]"),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.operational_events_check(limit: limit)
      |> print_events_check(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["events", "ls" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          since: :integer,
          ref: :string,
          kind: :string,
          severity: :string,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx events ls [--since <id>] [--ref <ref>] [--kind <kind>] [--severity info|notice|warning|critical] [-n 20] [--json]"
           ),
         :ok <- validate_optional_monitor_severity(opts[:severity]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_monitor_events(
        since_id: opts[:since],
        ref: opts[:ref],
        kind: opts[:kind],
        severity: opts[:severity],
        limit: limit
      )
      |> print_monitor_events(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["events", "unread" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          consumer: :string,
          ref: :string,
          kind: :string,
          severity: :string,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx events unread [--consumer <name>] [--ref <ref>] [--kind <kind>] [--severity info|notice|warning|critical] [-n 20] [--json]"
           ),
         :ok <- validate_optional_monitor_severity(opts[:severity]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(),
         {:ok, report} <-
           Workspace.unread_monitor_events(
             consumer: opts[:consumer],
             ref: opts[:ref],
             kind: opts[:kind],
             severity: opts[:severity],
             limit: limit
           ) do
      print_monitor_unread(report, json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["events", "ack" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [consumer: :string, to: :integer, latest: :boolean, json: :boolean]
      )

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx events ack [--consumer <name>] (--to <id> | --latest) [--json]"
           ),
         :ok <- validate_event_ack_opts(opts[:to], opts[:latest] || false),
         :ok <- validate_optional_non_negative("to", opts[:to]),
         :ok <- start_app(),
         {:ok, cursor} <-
           Workspace.acknowledge_monitor_events(
             consumer: opts[:consumer],
             to_id: opts[:to]
           ) do
      print_monitor_ack(cursor, json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["events", "cursor" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [consumer: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx events cursor [--consumer <name>] [--json]"),
         :ok <- start_app() do
      Workspace.monitor_event_status(consumer: opts[:consumer])
      |> print_monitor_event_status(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["events" | _args]) do
    {:error, "usage: #{events_usage()}"}
  end

  defp dispatch(["work", "ls" | args]), do: dispatch_work_board(args)
  defp dispatch(["work" | args]), do: dispatch_work_board(args)

  defp dispatch(["discover" | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [host: :string, managed: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx discover [--host <host>] [--managed]"),
         :ok <- start_app(),
         {:ok, report} <-
           Workspace.discover_sessions(host_name: opts[:host], all_tmux: !opts[:managed]) do
      print_discovery_report(report)
      :ok
    end
  end

  defp dispatch(["activity" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [host: :string, managed: :boolean, all_processes: :boolean]
      )

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx activity [--host <host>] [--managed] [--all-processes]"
           ),
         :ok <- start_app(),
         {:ok, report} <-
           Workspace.list_activity(
             host_name: opts[:host],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false
           ) do
      print_activity_report(report)
      :ok
    end
  end

  defp dispatch(["sessions", "snapshot" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          project: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          action: :string,
          ssh_target: :string,
          work_state: :string,
          n: :integer,
          save: :boolean,
          compact: :boolean,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    lines = opts[:n] || 40

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx sessions snapshot [--host <host>] [--managed] [--all-processes] [--type <type>] [--action <action>] [--ssh-target <target>] [--work-state <state>] [-n 40] [--save] [--json] [--compact]"
           ),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_positive("n", lines),
         :ok <- start_app(),
         {:ok, report} <-
           Workspace.snapshot_sessions(
             host_name: opts[:host],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             action: opts[:action],
             ssh_target: opts[:ssh_target],
             work_state: opts[:work_state],
             lines: lines
           ),
         {:ok, saved_count} <- maybe_save_snapshot(report, opts[:save] || false) do
      print_sessions_snapshot(report,
        json: opts[:json] || false,
        compact: opts[:compact] || false,
        saved: saved_count
      )

      :ok
    end
  end

  defp dispatch(["sessions", "summary" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          project: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          target: :string,
          observe: :boolean,
          lines: :integer,
          stale_seconds: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 20
    lines = opts[:lines] || 40
    stale_after_seconds = opts[:stale_seconds] || 300

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx sessions summary [--host <host>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--target <ssh-target>] [--observe] [--lines 40] [--stale-seconds 300] [-n 20] [--json]"
           ),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("stale-seconds", stale_after_seconds),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(),
         {:ok, summary} <-
           Workspace.session_summary(
             host_name: opts[:host],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             ssh_target: opts[:ssh_target],
             target: opts[:target],
             observe: opts[:observe] || false,
             lines: lines,
             stale_after_seconds: stale_after_seconds,
             limit: limit
           ) do
      print_sessions_summary(summary, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["sessions", "observe" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          action: :string,
          ssh_target: :string,
          work_state: :string,
          attention: :boolean,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    lines = opts[:n] || 40

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx sessions observe [--host <host>] [--managed] [--all-processes] [--type <type>] [--action <action>] [--ssh-target <target>] [--work-state <state>] [--attention] [-n 40] [--json]"
           ),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_positive("n", lines),
         :ok <- start_app(),
         {:ok, observation_report} <-
           Workspace.observe_sessions(
             host_name: opts[:host],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             action: opts[:action],
             ssh_target: opts[:ssh_target],
             work_state: opts[:work_state],
             lines: lines,
             attention: opts[:attention] || false
           ) do
      print_session_observe(observation_report.changes,
        saved: observation_report.saved,
        json: opts[:json] || false
      )

      :ok
    end
  end

  defp dispatch(["sessions", "changed" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [since: :integer, ref: :string, severity: :string, n: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = opts[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx sessions changed [--since <id>] [--ref <ref>] [--severity info|notice|warning|critical] [-n 20] [--json]"
           ),
         :ok <- validate_optional_monitor_severity(opts[:severity]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_monitor_events(
        since_id: opts[:since],
        ref: opts[:ref],
        severity: opts[:severity],
        kinds: MonitorEvents.change_kinds(),
        limit: limit
      )
      |> print_monitor_events(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["sessions", "ready" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          project: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          control: :string,
          observe: :boolean,
          lines: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    lines = opts[:lines] || 40
    limit = opts[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx sessions ready [--project <name>] [--host <host>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--control managed|ignored|protected|uncontrolled] [--no-observe] [--lines 40] [-n 20] [--json]"
           ),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_board_control(opts[:control]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(),
         {:ok, report} <-
           Workspace.session_profiles(
             host_name: opts[:host],
             project: opts[:project],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             ssh_target: opts[:ssh_target],
             control_mode: opts[:control],
             prompt_status: "ready",
             observe: Keyword.get(opts, :observe, true),
             lines: lines,
             limit: limit
           ) do
      print_session_profiles(report, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["sessions", "queues" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          project: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          work_state: :string,
          control: :string,
          observe: :boolean,
          lines: :integer,
          n: :integer,
          scan_limit: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    lines = opts[:lines] || 40
    queue_limit = opts[:n] || 5
    scan_limit = opts[:scan_limit] || 100

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx sessions queues [--project <name>] [--host <host>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--work-state <state>] [--control managed|ignored|protected|uncontrolled] [--no-observe] [--lines 40] [--scan-limit 100] [-n 5] [--json]"
           ),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_optional_work_board_control(opts[:control]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("n", queue_limit),
         :ok <- start_app(),
         {:ok, report} <-
           Workspace.session_queues(
             host_name: opts[:host],
             project: opts[:project],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             ssh_target: opts[:ssh_target],
             work_state: opts[:work_state],
             control_mode: opts[:control],
             observe: Keyword.get(opts, :observe, true),
             lines: lines,
             scan_limit: scan_limit,
             queue_limit: queue_limit
           ) do
      print_session_queues(report, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["sessions", "dossiers" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          project: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          work_state: :string,
          control: :string,
          next: :string,
          ref: :string,
          observe: :boolean,
          lines: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    lines = opts[:lines] || 40
    limit = opts[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx sessions dossiers [--ref <ref>] [--project <name>] [--host <host>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--work-state <state>] [--control managed|ignored|protected|uncontrolled] [--next <action>] [--no-observe] [--lines 40] [-n 50] [--json]"
           ),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_optional_work_board_control(opts[:control]),
         :ok <- validate_optional_dossier_next_action(opts[:next]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(),
         {:ok, report} <-
           Workspace.session_dossiers(
             ref: opts[:ref],
             project: opts[:project],
             host_name: opts[:host],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             ssh_target: opts[:ssh_target],
             work_state: opts[:work_state],
             control_mode: opts[:control],
             next_action: opts[:next],
             observe: Keyword.get(opts, :observe, true),
             lines: lines,
             limit: limit
           ) do
      print_session_dossiers(report, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["sessions", "profiles" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          project: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          work_state: :string,
          control: :string,
          next: :string,
          ref: :string,
          prompt_status: :string,
          observe: :boolean,
          lines: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    lines = opts[:lines] || 40
    limit = opts[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx sessions profiles [--ref <ref>] [--project <name>] [--host <host>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--work-state <state>] [--control managed|ignored|protected|uncontrolled] [--next <action>] [--prompt-status none|draft|ready|sent|blocked] [--no-observe] [--lines 40] [-n 50] [--json]"
           ),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_optional_work_board_control(opts[:control]),
         :ok <- validate_optional_dossier_next_action(opts[:next]),
         :ok <- validate_optional_prompt_status(opts[:prompt_status]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(),
         {:ok, report} <-
           Workspace.session_profiles(
             ref: opts[:ref],
             project: opts[:project],
             host_name: opts[:host],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             ssh_target: opts[:ssh_target],
             work_state: opts[:work_state],
             control_mode: opts[:control],
             next_action: opts[:next],
             prompt_status: opts[:prompt_status],
             observe: Keyword.get(opts, :observe, true),
             lines: lines,
             limit: limit
           ) do
      print_session_profiles(report, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["sessions", "reconcile" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          control: :string,
          observe: :boolean,
          lines: :integer,
          scan_limit: :integer,
          remote_limit: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 25
    lines = opts[:lines] || 80
    scan_limit = opts[:scan_limit] || 100
    remote_limit = opts[:remote_limit] || 200

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx sessions reconcile [--host <host>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--control managed|ignored|protected|uncontrolled] [--observe] [--lines 80] [--scan-limit 100] [--remote-limit 200] [-n 25] [--json]"
           ),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_board_control(opts[:control]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("remote-limit", remote_limit),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(),
         {:ok, reconciliation} <-
           Workspace.session_reconciliation(
             host_name: opts[:host],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             ssh_target: opts[:ssh_target],
             control_mode: opts[:control],
             observe: Keyword.get(opts, :observe, false),
             lines: lines,
             scan_limit: scan_limit,
             remote_limit: remote_limit,
             limit: limit
           ) do
      print_session_reconciliation(reconciliation, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["sessions", "recover" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          control: :string,
          observe: :boolean,
          lines: :integer,
          scan_limit: :integer,
          remote_limit: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 25
    lines = opts[:lines] || 80
    scan_limit = opts[:scan_limit] || 100
    remote_limit = opts[:remote_limit] || 200

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx sessions recover [--host <host>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--control managed|ignored|protected|uncontrolled] [--observe] [--lines 80] [--scan-limit 100] [--remote-limit 200] [-n 25] [--json]"
           ),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_board_control(opts[:control]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("remote-limit", remote_limit),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(),
         {:ok, recovery} <-
           Workspace.recovery_plan(
             host_name: opts[:host],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             ssh_target: opts[:ssh_target],
             control_mode: opts[:control],
             observe: Keyword.get(opts, :observe, false),
             lines: lines,
             scan_limit: scan_limit,
             remote_limit: remote_limit,
             limit: limit
           ) do
      print_recovery_plan(recovery, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["sessions", "history" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [ref: :string, work_state: :string, n: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = opts[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx sessions history [--ref <ref>] [--work-state <state>] [-n 20] [--json]"
           ),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_session_observations(
        ref: opts[:ref],
        work_state: opts[:work_state],
        limit: limit
      )
      |> print_session_history(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["sessions", "changes" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          ref: :string,
          work_state: :string,
          attention: :boolean,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx sessions changes [--ref <ref>] [--work-state <state>] [--attention] [-n 20] [--json]"
           ),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_session_changes(
        ref: opts[:ref],
        work_state: opts[:work_state],
        attention: opts[:attention] || false,
        limit: limit
      )
      |> print_session_changes(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["sessions", "stale" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          ref: :string,
          host: :string,
          type: :string,
          work_state: :string,
          seconds: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 20
    stale_after_seconds = opts[:seconds] || 300

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx sessions stale [--ref <ref>] [--host <host>] [--type <type>] [--work-state <state>] [--seconds 300] [-n 20] [--json]"
           ),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_positive("seconds", stale_after_seconds),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_stale_session_observations(
        ref: opts[:ref],
        host: opts[:host],
        type: opts[:type],
        work_state: opts[:work_state],
        stale_after_seconds: stale_after_seconds,
        limit: limit
      )
      |> print_stale_sessions(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["sessions", "broadcast" | args]) do
    {opts, message_parts, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          action: :string,
          ssh_target: :string,
          work_state: :string,
          attention: :boolean,
          n: :integer,
          yes: :boolean,
          no_enter: :boolean,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    lines = opts[:n] || 40
    message = Enum.join(message_parts, " ") |> String.trim()

    with :ok <- validate_options(invalid),
         {:ok, message} <-
           required_message(
             message,
             "jx sessions broadcast \"<message>\" [--host <host>] [--type <type>] [--work-state <state>] [--attention] [-n 40] [--yes] [--no-enter] [--json]"
           ),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_positive("n", lines),
         :ok <- start_app(),
         {:ok, report} <-
           Workspace.broadcast_sessions(message,
             host_name: opts[:host],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             action: opts[:action],
             ssh_target: opts[:ssh_target],
             work_state: opts[:work_state],
             attention: opts[:attention] || false,
             lines: lines,
             execute: opts[:yes] || false,
             enter: !opts[:no_enter]
           ) do
      print_broadcast_report(report, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["sessions", "remote" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          target: :string,
          probe: :boolean,
          force: :boolean,
          timeout_ms: :integer,
          json: :boolean
        ]
      )

    timeout_ms = opts[:timeout_ms] || 5_000

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx sessions remote [--target <ssh-target>] [--probe] [--force] [--timeout-ms 5000] [--json]"
           ),
         :ok <- validate_positive("timeout-ms", timeout_ms),
         :ok <- start_app() do
      if opts[:probe] do
        with {:ok, probes} <-
               Workspace.probe_remote_sessions(
                 target: opts[:target],
                 timeout_ms: timeout_ms,
                 force: opts[:force] || false
               ) do
          print_sessions_remote_probes(probes, json: opts[:json] || false)
          :ok
        end
      else
        with {:ok, candidates} <- Workspace.remote_session_candidates(target: opts[:target]) do
          print_sessions_remote_candidates(candidates, json: opts[:json] || false)
          :ok
        end
      end
    end
  end

  defp dispatch(["sessions", "ls" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          status: :string,
          runner: :string,
          workspace: :string,
          assignment: :string,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, runner_sessions_ls_usage()),
         :ok <- validate_optional_runner_session_status(opts[:status]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_runner_sessions(
        status: opts[:status],
        runner_id: opts[:runner],
        workspace_id: opts[:workspace],
        assignment_id: opts[:assignment],
        limit: limit
      )
      |> print_runner_sessions(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["sessions", "show", session_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx sessions show <session-id> [--json]"),
         :ok <- start_app(),
         session when not is_nil(session) <- Workspace.get_runner_session(session_id) do
      print_runner_session("session", session, json: opts[:json] || false)
      :ok
    else
      nil -> {:error, :runner_session_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch(["sessions", "logs", session_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [lines: :integer, json: :boolean])

    lines = opts[:lines] || 80

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx sessions logs <session-id> [--lines 80] [--json]"),
         :ok <- validate_positive("lines", lines),
         :ok <- start_app(),
         {:ok, result} <- Workspace.runner_session_logs(session_id, lines: lines) do
      print_runner_session_logs(result, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["sessions", "attach", session_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx sessions attach <session-id> [--json]"),
         :ok <- start_app(),
         {:ok, result} <- Workspace.runner_session_attach_plan(session_id) do
      print_runner_session_attach(result, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["sessions", "expire" | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx sessions expire [--json]"),
         :ok <- start_app() do
      Workspace.expire_runner_sessions()
      |> print_runner_session_expiration(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["sessions" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          action: :string,
          ssh_target: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx sessions [--host <host>] [--managed] [--all-processes] [--type <type>] [--action <action>] [--ssh-target <target>] [--json]"
           ),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- start_app(),
         {:ok, report} <-
           Workspace.list_sessions(
             host_name: opts[:host],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             action: opts[:action],
             ssh_target: opts[:ssh_target]
           ) do
      print_sessions_report(report, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["directives", "ls" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [host: :string, task: :string, n: :integer],
        aliases: [n: :n]
      )

    limit = opts[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(rest, "jx directives ls [--host <host>] [--task <task-id>] [-n 20]"),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_directives(host_name: opts[:host], task_ref: opts[:task], limit: limit)
      |> print_directives()

      :ok
    end
  end

  defp dispatch(["directives" | _args]) do
    {:error, "usage: jx directives ls [--host <host>] [--task <task-id>] [-n 20]"}
  end

  defp dispatch(["operations", "ls" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [ref: :string, action: :string, status: :string, n: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = opts[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx operations ls [--ref <ref>] [--action <action>] [--status executed|skipped|error] [-n 20] [--json]"
           ),
         :ok <- validate_optional_operation_status(opts[:status]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_operation_executions(
        ref: opts[:ref],
        action: opts[:action],
        status: opts[:status],
        limit: limit
      )
      |> print_operation_executions(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["operations" | _args]) do
    {:error,
     "usage: jx operations ls [--ref <ref>] [--action <action>] [--status executed|skipped|error] [-n 20] [--json]"}
  end

  defp dispatch(["actions" | args]), do: ActionsCLI.run(args, start_app: &start_app/0)

  defp dispatch(["runners" | args]), do: RunnersCLI.run(args, start_app: &start_app/0)

  defp dispatch(["agents" | args]), do: AgentsCLI.run(args, start_app: &start_app/0)

  defp dispatch(["assignments" | args]), do: AssignmentsCLI.run(args, start_app: &start_app/0)

  defp dispatch(["queue", "ls" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          kind: :string,
          workspace: :string,
          owner: :string,
          risk: :string,
          freshness: :string,
          sort: :string,
          stale_after_seconds: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, queue_ls_usage()),
         :ok <- validate_optional_queue_kind(opts[:kind]),
         :ok <- validate_optional_queue_risk(opts[:risk]),
         :ok <- validate_optional_freshness(opts[:freshness]),
         :ok <- validate_optional_queue_sort(opts[:sort]),
         :ok <- validate_positive("n", limit),
         :ok <- validate_optional_positive("stale-after-seconds", opts[:stale_after_seconds]),
         :ok <- start_app() do
      Workspace.operational_queue(
        kind: opts[:kind],
        workspace_id: opts[:workspace],
        owner: opts[:owner],
        risk: opts[:risk],
        freshness: opts[:freshness],
        sort: opts[:sort],
        stale_after_seconds: opts[:stale_after_seconds] || 15 * 60,
        limit: limit
      )
      |> print_queue(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["queue", "workspace", workspace_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [stale_after_seconds: :integer, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx queue workspace <workspace-id> [--json]"),
         :ok <- validate_optional_positive("stale-after-seconds", opts[:stale_after_seconds]),
         :ok <- start_app() do
      workspace_id
      |> Workspace.operational_workspace(
        stale_after_seconds: opts[:stale_after_seconds] || 15 * 60
      )
      |> print_queue_workspace(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["queue", "rebuild" | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx queue rebuild [--json]"),
         :ok <- start_app() do
      Workspace.operational_rebuilt_state()
      |> print_rebuilt_state(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["queue" | _args]),
    do:
      {:error,
       "usage: #{queue_ls_usage()} | jx queue workspace <workspace-id> [--json] | jx queue rebuild [--json]"}

  defp dispatch(["dashboard", "workspace", workspace_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [stale_after_seconds: :integer, events: :integer, json: :boolean]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, dashboard_workspace_usage()),
         :ok <- validate_optional_positive("stale-after-seconds", opts[:stale_after_seconds]),
         :ok <- validate_optional_positive("events", opts[:events]),
         :ok <- start_app() do
      workspace_id
      |> Workspace.operator_dashboard_workspace(
        stale_after_seconds: opts[:stale_after_seconds] || 15 * 60,
        event_limit: opts[:events] || 25
      )
      |> print_operator_dashboard_workspace(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["dashboard", "runner", runner_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [n: :integer, events: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = opts[:n] || 100

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, dashboard_runner_usage()),
         :ok <- validate_positive("n", limit),
         :ok <- validate_optional_positive("events", opts[:events]),
         :ok <- start_app(),
         {:ok, report} <-
           Workspace.operator_dashboard_runner(runner_id,
             limit: limit,
             event_limit: opts[:events] || 25
           ) do
      print_operator_dashboard_runner(report, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["dashboard", "assignment", assignment_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [n: :integer, events: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = opts[:n] || 100

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, dashboard_assignment_usage()),
         :ok <- validate_positive("n", limit),
         :ok <- validate_optional_positive("events", opts[:events]),
         :ok <- start_app(),
         {:ok, report} <-
           Workspace.operator_dashboard_assignment(assignment_id,
             limit: limit,
             event_limit: opts[:events] || 25
           ) do
      print_operator_dashboard_assignment(report, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["dashboard", "action", action_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [n: :integer, events: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = opts[:n] || 100

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, dashboard_action_usage()),
         :ok <- validate_positive("n", limit),
         :ok <- validate_optional_positive("events", opts[:events]),
         :ok <- start_app(),
         {:ok, report} <-
           Workspace.operator_dashboard_action(action_id,
             limit: limit,
             event_limit: opts[:events] || 25
           ) do
      print_operator_dashboard_action(report, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["dashboard" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          stale_after_seconds: :integer,
          events: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, dashboard_usage()),
         :ok <- validate_positive("n", limit),
         :ok <- validate_optional_positive("events", opts[:events]),
         :ok <- validate_optional_positive("stale-after-seconds", opts[:stale_after_seconds]),
         :ok <- start_app() do
      Workspace.operator_dashboard(
        limit: limit,
        event_limit: opts[:events] || 25,
        stale_after_seconds: opts[:stale_after_seconds] || 15 * 60
      )
      |> print_operator_dashboard(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["runtimes" | args]), do: RuntimesCLI.run(args, start_app: &start_app/0)

  defp dispatch(["leases" | args]), do: LeasesCLI.run(args, start_app: &start_app/0)

  defp dispatch(["timeline", scope, id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [n: :integer, json: :boolean], aliases: [n: :n])

    limit = opts[:n] || 100

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx timeline workspace|approval|action|assignment|agent|runner|session <id> [-n 100] [--json]"
           ),
         :ok <- validate_timeline_scope(scope),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      scope
      |> Workspace.operational_timeline(id, limit: limit)
      |> print_timeline(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["timeline" | _args]),
    do:
      {:error,
       "usage: jx timeline workspace|approval|action|assignment|agent|runner|session <id> [-n 100] [--json]"}

  defp dispatch(["approvals" | args]), do: ApprovalsCLI.run(args, start_app: &start_app/0)

  defp dispatch(["notifications", "ls" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          status: :string,
          severity: :string,
          ref: :string,
          project: :string,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx notifications ls [--status unread|acknowledged|dismissed] [--severity info|notice|warning|critical] [--ref <ref>] [--project <name>] [-n 50] [--json]"
           ),
         :ok <- validate_optional_notification_status(opts[:status]),
         :ok <- validate_optional_monitor_severity(opts[:severity]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_notifications(
        status: opts[:status],
        severity: opts[:severity],
        ref: opts[:ref],
        project: opts[:project],
        limit: limit
      )
      |> print_notifications(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["notifications", "ack" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [all: :boolean, ref: :string, project: :string, json: :boolean]
      )

    with :ok <- validate_options(invalid),
         {:ok, ack_opts} <- notification_ack_opts(rest, opts),
         :ok <- start_app(),
         {:ok, result} <- Workspace.acknowledge_notifications(ack_opts) do
      print_notification_ack(result, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["notifications", "compact" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [ref: :string, project: :string, json: :boolean]
      )

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx notifications compact [--ref <ref>] [--project <name>] [--json]"
           ),
         :ok <- start_app(),
         {:ok, result} <-
           Workspace.compact_notifications(ref: opts[:ref], project: opts[:project]) do
      print_notification_compaction(result, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["notifications" | _args]) do
    {:error,
     "usage: jx notifications ls [--status unread|acknowledged|dismissed] [--severity info|notice|warning|critical] [--ref <ref>] [--project <name>] [-n 50] [--json] | jx notifications ack <notification-id>|--all [--ref <ref>] [--project <name>] [--json] | jx notifications compact [--ref <ref>] [--project <name>] [--json]"}
  end

  defp dispatch(["policy", "overview" | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx policy overview [--json]"),
         :ok <- start_app() do
      print_policy_overview(Workspace.policy_overview(), json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["policy", "check", action | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx policy check <action> [--json]"),
         :ok <- start_app() do
      result = Workspace.policy_check(action)
      if opts[:json], do: print_json(result), else: print_policy_rule(result)
      :ok
    end
  end

  defp dispatch(["policy", "tiers" | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx policy tiers [--json]") do
      print_policy_tiers(JX.OperationPolicy.safety_tiers(), json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["policy" | _args]) do
    {:error,
     "usage: jx policy overview [--json] | jx policy check <action> [--json] | jx policy tiers [--json]"}
  end

  defp dispatch(["controls", "ls" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [mode: :string, n: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = opts[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx controls ls [--mode managed|ignored|protected] [-n 50] [--json]"
           ),
         :ok <- validate_optional_session_control_mode(opts[:mode]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_session_controls(mode: opts[:mode], limit: limit)
      |> print_session_controls(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["controls" | _args]) do
    {:error, "usage: jx controls ls [--mode managed|ignored|protected] [-n 50] [--json]"}
  end

  defp dispatch(["watch", "add", ref | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          goal: :string,
          success: :string,
          blocker: :string,
          mode: :string,
          prompt: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, watch_add_usage()),
         :ok <- validate_optional_watch_mode(opts[:mode]),
         :ok <- validate_watch_patterns(opts[:success], opts[:blocker]),
         {:ok, goal} <- required_option(opts, :goal, watch_add_usage()),
         :ok <- start_app(),
         {:ok, watch} <-
           Workspace.add_watch(ref, %{
             goal: goal,
             success_pattern: opts[:success] || "",
             blocker_pattern: opts[:blocker] || "",
             mode: opts[:mode] || "notify",
             prompt: opts[:prompt] || ""
           }) do
      print_session_watch(watch, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["watch", "ls" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [status: :string, ref: :string, n: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = opts[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx watch ls [--status active|completed|blocked|cancelled] [--ref <ref>] [-n 50] [--json]"
           ),
         :ok <- validate_optional_watch_status(opts[:status]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_watches(status: opts[:status], ref: opts[:ref], limit: limit)
      |> print_session_watches(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["watch", "review", watch_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          observe: :boolean,
          lines: :integer,
          all_processes: :boolean,
          json: :boolean
        ]
      )

    lines = opts[:lines] || 160

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx watch review <watch-id> [--no-observe] [--lines 160] [--all-processes] [--json]"
           ),
         :ok <- validate_positive("lines", lines),
         :ok <- start_app(),
         {:ok, review} <-
           Workspace.review_watch(watch_id,
             observe: Keyword.get(opts, :observe, true),
             lines: lines,
             all_processes: opts[:all_processes] || false
           ) do
      print_watch_review(review, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["watch", "complete", watch_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [summary: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(rest, "jx watch complete <watch-id> [--summary <text>] [--json]"),
         :ok <- start_app(),
         {:ok, watch} <- Workspace.complete_watch(watch_id, opts[:summary] || "manual completion") do
      print_session_watch(watch, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["watch", "cancel", watch_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [summary: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx watch cancel <watch-id> [--summary <text>] [--json]"),
         :ok <- start_app(),
         {:ok, watch} <- Workspace.cancel_watch(watch_id, opts[:summary] || "manual cancel") do
      print_session_watch(watch, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch(["watch" | _args]), do: {:error, "usage: #{watch_usage()}"}

  defp dispatch(["operator", "profile", "set" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          name: :string,
          preferences: :string,
          style: :string,
          escalation: :string,
          notes: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx operator profile set [--name <name>] [--preferences <text>] [--style <text>] [--escalation <text>] [--notes <text>] [--json]"
           ),
         :ok <- start_app(),
         {:ok, _profile} <- Workspace.set_operator_profile(operator_profile_attrs(opts)) do
      Workspace.operator_profile()
      |> print_operator_profile(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["operator", "profile" | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx operator profile [--json]"),
         :ok <- start_app() do
      Workspace.operator_profile()
      |> print_operator_profile(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["operator" | _args]) do
    {:error,
     "usage: jx operator profile [--json] | jx operator profile set [--name <name>] [--preferences <text>] [--style <text>] [--escalation <text>] [--notes <text>] [--json]"}
  end

  defp dispatch(["remote", "ls" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [target: :string, ref: :string, n: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = opts[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx remote ls [--target <ssh-target>] [--ref <ref>] [-n 50] [--json]"
           ),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_remote_session_observations(
        target: opts[:target],
        local_ref: opts[:ref],
        limit: limit
      )
      |> print_remote_observations(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch(["remote" | _args]) do
    {:error, "usage: jx remote ls [--target <ssh-target>] [--ref <ref>] [-n 50] [--json]"}
  end

  defp dispatch(["tmux" | args]), do: TmuxCLI.run(args, start_app: &start_app/0)

  defp dispatch(["process", "ls" | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [kind: :string, all: :boolean])

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx process ls [--kind codex|claude|opencode|ssh|sshd|tmux] [--all]"
           ),
         {:ok, kinds} <- process_kinds(opts[:kind]),
         {:ok, processes} <- ProcessInventory.list(kinds: kinds, all: opts[:all] || false) do
      print_processes(processes)
      :ok
    end
  end

  defp dispatch(["process" | _args]) do
    {:error, "usage: jx process ls [--kind codex|claude|opencode|ssh|sshd|tmux] [--all]"}
  end

  defp dispatch(["ssh", "ls"]) do
    with :ok <- start_app(),
         {:ok, sessions} <- SSHSessions.list(Workspace.list_hosts()) do
      print_ssh_sessions(sessions)
      :ok
    end
  end

  defp dispatch(["ssh", "probe" | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [target: :string])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx ssh probe [--target <target>]"),
         {:ok, targets} <- ssh_probe_targets(opts[:target]),
         {:ok, probes} <- SSHSessions.probe(targets) do
      print_ssh_probes(probes)
      :ok
    end
  end

  defp dispatch(["ssh", "pane-probe" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          all: :boolean,
          target: :string,
          dry_run: :boolean,
          server: :string,
          session: :string,
          window: :integer,
          pane: :integer,
          timeout_ms: :integer
        ]
      )

    server = opts[:server] || Tmux.managed_server()
    window = opts[:window] || 0
    pane = opts[:pane] || 0
    timeout_ms = opts[:timeout_ms] || 5_000

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, ssh_pane_probe_usage()),
         :ok <- validate_non_negative("window", window),
         :ok <- validate_non_negative("pane", pane),
         :ok <- validate_positive("timeout-ms", timeout_ms) do
      if opts[:all] do
        run_ssh_pane_probe_all(opts[:target], timeout_ms, opts[:dry_run] || false)
      else
        run_ssh_pane_probe_one(opts, server, window, pane, timeout_ms)
      end
    end
  end

  defp dispatch(["ssh" | _args]) do
    {:error, "usage: jx ssh ls | jx ssh probe [--target <target>] | #{ssh_pane_probe_usage()}"}
  end

  defp dispatch(["session" | args]), do: SessionCLI.run(args, start_app: &start_app/0)

  defp dispatch(["task", "adopt-tmux", project_name | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          session: :string,
          worktree: :string,
          agent: :string,
          server: :string,
          window: :integer,
          pane: :integer
        ]
      )

    agent_name = opts[:agent] || "claude"
    server = opts[:server] || Tmux.managed_server()
    window = opts[:window] || 0
    pane = opts[:pane] || 0

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, task_adopt_tmux_usage()),
         :ok <- validate_agent_name(agent_name),
         :ok <- validate_tmux_server(server),
         :ok <- validate_non_negative("window", window),
         :ok <- validate_non_negative("pane", pane),
         {:ok, session_name} <- required_option(opts, :session, task_adopt_tmux_usage()),
         {:ok, worktree_path} <- required_option(opts, :worktree, task_adopt_tmux_usage()),
         :ok <- start_app(),
         {:ok, task} <-
           Workspace.adopt_tmux_task(project_name,
             session_name: session_name,
             worktree_path: worktree_path,
             agent_name: agent_name,
             tmux_server: server,
             window: window,
             pane: pane
           ) do
      IO.puts("""
      task #{task.task_id} adopted
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

  defp dispatch(["task", "adopt-activity", project_name | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          session: :string,
          agent: :string,
          server: :string,
          window: :integer,
          pane: :integer
        ]
      )

    agent_name = opts[:agent] || "claude"
    window = opts[:window] || 0
    pane = opts[:pane] || 0

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, task_adopt_activity_usage()),
         :ok <- validate_agent_name(agent_name),
         {:ok, server} <- required_option(opts, :server, task_adopt_activity_usage()),
         :ok <- validate_tmux_server(server),
         :ok <- validate_non_negative("window", window),
         :ok <- validate_non_negative("pane", pane),
         {:ok, session_name} <- required_option(opts, :session, task_adopt_activity_usage()),
         :ok <- start_app(),
         {:ok, task} <-
           Workspace.adopt_activity_task(project_name,
             session_name: session_name,
             agent_name: agent_name,
             tmux_server: server,
             window: window,
             pane: pane
           ) do
      IO.puts("""
      task #{task.task_id} adopted from activity
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

  defp dispatch(["task", "send", task_id | args]) do
    {opts, message_parts, invalid} =
      OptionParser.parse(args,
        strict: [window: :integer, pane: :integer, no_enter: :boolean]
      )

    message = Enum.join(message_parts, " ") |> String.trim()

    with :ok <- start_app(),
         :ok <- validate_options(invalid),
         :ok <- validate_optional_non_negative("window", opts[:window]),
         :ok <- validate_optional_non_negative("pane", opts[:pane]),
         {:ok, message} <- required_message(message, task_send_usage()),
         {:ok, directive} <-
           Workspace.send(task_id, message, task_send_opts(opts)) do
      IO.puts(
        "directive #{directive.directive_id} sent to task #{task_id}:#{directive.window}.#{directive.pane}"
      )

      :ok
    end
  end

  defp dispatch(["task" | _args]) do
    {:error,
     "usage: #{task_adopt_tmux_usage()} | #{task_adopt_activity_usage()} | #{task_send_usage()}"}
  end

  defp dispatch(["attach", task_id]) do
    with :ok <- start_app() do
      Workspace.attach(task_id)
    end
  end

  defp dispatch(["logs", task_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [f: :boolean, n: :integer], aliases: [f: :f, n: :n])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, "jx logs <task-id> [-n 200] [-f]"),
         :ok <- start_app() do
      Workspace.logs(task_id, lines: opts[:n] || 200, follow: opts[:f] || false)
    end
  end

  defp dispatch(["stop", task_id]) do
    with :ok <- start_app(),
         {:ok, _task} <- Workspace.stop(task_id) do
      IO.puts("task #{task_id} stopped")
      :ok
    end
  end

  defp dispatch(["version"]) do
    IO.puts("jx #{app_version()}")
    :ok
  end

  defp dispatch(["modes" | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid) do
      dispatch_modes(rest, opts)
    end
  end

  defp dispatch(["help" | args]), do: print_help(args)
  defp dispatch(["--help"]), do: print_usage()
  defp dispatch(["-h"]), do: print_usage()
  defp dispatch([]), do: print_usage()
  defp dispatch(_args), do: {:error, usage_text()}

  defp assign_goal_line(%{goal_objective: goal_objective})
       when is_binary(goal_objective) and goal_objective != "" do
    "goal: codex\n"
  end

  defp assign_goal_line(_task), do: ""

  defp dispatch_devide(args) do
    with :ok <- maybe_start_devide_state(args) do
      case DevIDECLI.run(args, writer: &IO.write/1, trap_signals: true) do
        {0, ""} ->
          :ok

        {0, output} ->
          IO.write(output)
          :ok

        {_code, output} ->
          {:error, String.trim_trailing(output)}
      end
    end
  end

  defp maybe_start_devide_state(args) do
    if DevIDECLI.requires_state?(args), do: start_app(), else: :ok
  end

  defp help_args(global_opts, []), do: if(global_opts[:help], do: ["help"], else: [])
  defp help_args(global_opts, args), do: if(global_opts[:help], do: ["help" | args], else: args)

  defp dispatch_modes([], opts) do
    print_usage_modes(UsageModes.all(), json: opts[:json] || false)
    :ok
  end

  defp dispatch_modes(["playbook", mode_id], opts), do: dispatch_mode_playbook(mode_id, opts)
  defp dispatch_modes([mode_id], opts), do: dispatch_mode_playbook(mode_id, opts)
  defp dispatch_modes(_args, _opts), do: {:error, "usage: #{modes_usage()}"}

  defp dispatch_mode_playbook(mode_id, opts) do
    case UsageModes.playbook(mode_id) do
      {:ok, playbook} ->
        print_usage_mode_playbook(playbook, json: opts[:json] || false)
        :ok

      {:error, :mode_not_found} ->
        {:error,
         "unknown mode #{inspect(mode_id)}; expected one of: #{Enum.join(UsageModes.ids(), ", ")}"}
    end
  end

  defp dispatch_tui_plan(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, tui_plan_usage()) do
      TUI.plan()
      |> print_tui_plan(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch_tui_snapshot(args, command_opts) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          consumer: :string,
          host: :string,
          project: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          work_state: :string,
          control: :string,
          observe: :boolean,
          lines: :integer,
          scan_limit: :integer,
          stale_after_seconds: :integer,
          interval_ms: :integer,
          iterations: :integer,
          watch: :boolean,
          interactive: :boolean,
          clear: :boolean,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    watch? = Keyword.get(command_opts, :watch, false) || opts[:watch] || false
    json? = opts[:json] || false

    explicit_interactive? =
      (Keyword.get(command_opts, :interactive) == true or opts[:interactive]) || false

    default_interactive? = Keyword.get(command_opts, :interactive) == :default
    interactive? = !watch? and !json? and (explicit_interactive? or default_interactive?)
    limit = opts[:n] || 5
    lines = opts[:lines] || 80
    scan_limit = opts[:scan_limit] || max(limit * 5, 100)
    stale_after_seconds = opts[:stale_after_seconds] || 120
    interval_ms = opts[:interval_ms] || TUI.default_interval_ms()
    iterations = opts[:iterations] || if(watch?, do: 0, else: 1)
    clear? = Keyword.get(opts, :clear, watch? || interactive?)

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, tui_snapshot_usage()),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_optional_work_board_control(opts[:control]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("stale-after-seconds", stale_after_seconds),
         :ok <- validate_positive("interval-ms", interval_ms),
         :ok <- validate_non_negative("iterations", iterations),
         :ok <- validate_tui_mode_options(explicit_interactive?, watch?, json?),
         :ok <- start_app() do
      tui_opts = [
        consumer: opts[:consumer],
        host_name: opts[:host],
        project: opts[:project],
        all_tmux: !opts[:managed],
        all_processes: opts[:all_processes] || false,
        type: opts[:type],
        ssh_target: opts[:ssh_target],
        work_state: opts[:work_state],
        control_mode: opts[:control],
        observe: Keyword.get(opts, :observe, true),
        lines: lines,
        scan_limit: scan_limit,
        stale_after_seconds: stale_after_seconds,
        limit: limit
      ]

      cond do
        interactive? ->
          run_tui_interactive(tui_opts, selected: 0, clear: clear?)

        json? ->
          with {:ok, snapshot} <- TUI.snapshot(tui_opts) do
            print_tui_snapshot(snapshot, json: true)
            :ok
          end

        true ->
          run_tui_watch(tui_opts, iterations, interval_ms, clear: clear?)
      end
    end
  end

  defp dispatch_work_board(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          managed: :boolean,
          all_processes: :boolean,
          type: :string,
          ssh_target: :string,
          work_state: :string,
          control: :string,
          lines: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    lines = opts[:lines] || 40
    limit = opts[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <-
           expect_no_args(
             rest,
             "jx work [ls] [--host <host>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--work-state <state>] [--control managed|ignored|protected|uncontrolled] [--lines 40] [-n 50] [--json]"
           ),
         :ok <- validate_optional_session_type(opts[:type]),
         :ok <- validate_optional_work_state(opts[:work_state]),
         :ok <- validate_optional_work_board_control(opts[:control]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(),
         {:ok, board} <-
           Workspace.work_board(
             host_name: opts[:host],
             all_tmux: !opts[:managed],
             all_processes: opts[:all_processes] || false,
             type: opts[:type],
             ssh_target: opts[:ssh_target],
             work_state: opts[:work_state],
             control_mode: opts[:control],
             lines: lines,
             limit: limit
           ) do
      print_work_board(board, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch_wake(["add" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          name: :string,
          message: :string,
          project: :string,
          ref: :string,
          severity: :string,
          at: :string,
          in: :string,
          every: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, wake_add_usage()),
         {:ok, message} <- required_option(opts, :message, wake_add_usage()),
         :ok <- validate_optional_monitor_severity(opts[:severity]),
         {:ok, schedule_attrs} <- wake_schedule_attrs(opts, wake_add_usage()),
         :ok <- start_app(),
         {:ok, trigger} <-
           Workspace.add_wake_trigger(
             Map.merge(schedule_attrs, %{
               name: opts[:name] || "",
               message: message,
               project: opts[:project] || "",
               ref: opts[:ref] || "",
               severity: opts[:severity] || "warning"
             })
           ) do
      print_wake_trigger(trigger, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch_wake(["ls" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          status: :string,
          project: :string,
          ref: :string,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = opts[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, wake_ls_usage()),
         :ok <- validate_optional_wake_trigger_status(opts[:status]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app() do
      Workspace.list_wake_triggers(
        status: opts[:status],
        project: opts[:project],
        ref: opts[:ref],
        limit: limit
      )
      |> print_wake_triggers(json: opts[:json] || false)

      :ok
    end
  end

  defp dispatch_wake(["run-due" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [limit: :integer, json: :boolean]
      )

    limit = opts[:limit] || 20

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, wake_run_due_usage()),
         :ok <- validate_positive("limit", limit),
         :ok <- start_app(),
         {:ok, report} <- Workspace.run_due_wake_triggers(limit: limit) do
      print_wake_trigger_run_report(report, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch_wake(["remove", trigger_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, wake_remove_usage()),
         :ok <- start_app(),
         {:ok, trigger} <- Workspace.cancel_wake_trigger(trigger_id) do
      print_wake_trigger(trigger, json: opts[:json] || false)
      :ok
    end
  end

  defp dispatch_wake(["remove" | _args]), do: {:error, "usage: #{wake_remove_usage()}"}

  defp dispatch_wake(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          message: :string,
          project: :string,
          ref: :string,
          severity: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, wake_usage()),
         {:ok, message} <- required_option(opts, :message, wake_usage()),
         :ok <- validate_optional_monitor_severity(opts[:severity]),
         :ok <- start_app(),
         {:ok, result} <-
           Workspace.wake(%{
             message: message,
             project: opts[:project] || "",
             ref: opts[:ref] || "",
             severity: opts[:severity] || "warning",
             source: "cli"
           }) do
      print_wake(result, json: opts[:json] || false)
      :ok
    end
  end

  defp task_adopt_tmux_usage do
    "jx task adopt-tmux <project> --session <name> --worktree <path> [--server <server>] [--window 0] [--pane 0] [--agent claude|opencode|codex]"
  end

  defp task_adopt_activity_usage do
    "jx task adopt-activity <project> --server <server> --session <name> [--window 0] [--pane 0] [--agent claude|opencode|codex]"
  end

  defp ssh_pane_probe_usage do
    "jx ssh pane-probe --all [--target <ssh-target>] [--dry-run] [--timeout-ms 5000] | jx ssh pane-probe --session <name> [--server <server>] [--window 0] [--pane 0] [--timeout-ms 5000]"
  end

  defp monitor_usage do
    "jx monitor scan|run|start [--host <host>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--work-state <state>] [--control managed|ignored|protected|uncontrolled] [--prompt-status none|draft|ready|sent|blocked] [--no-observe] [--lines 40] [--scan-limit 100] [--queue-limit 5] [--event-limit 20] [--interval-ms 30000] [--iterations 0] [--json] | jx monitor status [--consumer <name>] [--json]"
  end

  defp tui_plan_usage do
    "jx tui plan [--json]"
  end

  defp tui_snapshot_usage do
    "jx tui [--consumer <name>] [--project <name>] [--host <host>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--work-state <state>] [--control managed|ignored|protected|uncontrolled] [--no-observe] [--lines 80] [--scan-limit 100] [--stale-after-seconds 120] [-n 5] [--interactive] [--no-clear] | jx tui snapshot [same filters] [--json] | jx tui watch [same filters] [--interval-ms 5000] [--iterations <n>] [--no-clear] | jx tui interactive [same filters]"
  end

  defp tui_usage do
    "#{tui_snapshot_usage()} | #{tui_plan_usage()}"
  end

  defp watch_usage do
    "#{watch_add_usage()} | jx watch ls [--status active|completed|blocked|cancelled] [--ref <ref>] [-n 50] [--json] | jx watch review <watch-id> [--no-observe] [--lines 160] [--all-processes] [--json] | jx watch complete <watch-id> [--summary <text>] [--json] | jx watch cancel <watch-id> [--summary <text>] [--json]"
  end

  defp watch_add_usage do
    "jx watch add <ref> --goal <text> (--success <pattern> | --blocker <pattern>) [--mode notify|hold|prompt] [--prompt <text>] [--json]"
  end

  defp orchestrate_usage do
    "jx orchestrate step|run|start [--consumer orchestrator] [--execute] [--yes] [--ack|--no-ack] [--auto-plan] [--host <host>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--work-state <state>] [--control managed|ignored|protected|uncontrolled] [--prompt-status none|draft|ready|sent|blocked] [--no-observe] [--lines 40] [--scan-limit 100] [--queue-limit 5] [--event-limit 50] [--decision-limit 20] [--min-observe-age-seconds 30] [--interval-ms 30000] [--iterations 0] [--no-enter] [--json]"
  end

  defp events_usage do
    "jx events check [-n 10000] [--json] | jx events ls [--since <id>] [--ref <ref>] [--kind <kind>] [--severity info|notice|warning|critical] [-n 20] [--json] | jx events unread [--consumer <name>] [--ref <ref>] [--kind <kind>] [--severity info|notice|warning|critical] [-n 20] [--json] | jx events ack [--consumer <name>] (--to <id> | --latest) [--json] | jx events cursor [--consumer <name>] [--json]"
  end

  defp ci_digest_usage do
    "jx ci digest <pr-number> --repo <owner/repo> [--no-logs] [--json]"
  end

  defp ci_watch_usage do
    "jx ci watch <pr-number> --repo <owner/repo> [--ref <session-ref>] [--project <name>] [--head-sha <sha>] [--mode notify|hold|prompt] [--goal <text>] [--pass-prompt <text>] [--fail-prompt <text>] [--json]"
  end

  defp ci_watches_usage do
    "jx ci watches [--status active|passed|failed|cancelled|superseded] [--repo <owner/repo>] [--ref <session-ref>] [--project <name>] [-n 50] [--json]"
  end

  defp ci_review_usage do
    "jx ci review <watch-id> [--no-logs] [--json]"
  end

  defp ci_cancel_usage do
    "jx ci cancel <watch-id> [--summary <text>] [--json]"
  end

  defp ci_usage do
    "#{ci_digest_usage()} | #{ci_watch_usage()} | #{ci_watches_usage()} | #{ci_review_usage()} | #{ci_cancel_usage()}"
  end

  defp portfolio_summary_usage do
    "jx portfolio summary [--host <host>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--work-state <state>] [--control managed|ignored|protected|uncontrolled] [--no-observe] [--lines 80] [--scan-limit 100] [-n 25] [--json]"
  end

  defp promotion_preflight_usage do
    "jx promote preflight <project> --from <source-branch> --to <target-branch> [--json]"
  end

  defp promotion_run_usage do
    "jx promote run <project> --from <source-branch> --to <target-branch> [--json]"
  end

  defp promote_usage do
    "#{promotion_preflight_usage()} | #{promotion_run_usage()}"
  end

  defp repo_doctor_usage do
    "jx repo doctor <name> [--host <host>] [--base <branch>] [--promote-to <branch>] [--json]"
  end

  defp repo_gate_usage do
    "jx repo gate <name> [--host <host>] [--base <branch>] [--promote-to <branch>] [--json]"
  end

  defp repo_usage do
    "#{repo_doctor_usage()} | #{repo_gate_usage()}"
  end

  defp call_brief_usage do
    "jx call brief [--host <host>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--work-state <state>] [--control managed|ignored|protected|uncontrolled] [--observe] [--lines 80] [--scan-limit 100] [-n 5] [--json]"
  end

  defp call_handoff_add_usage do
    "jx call handoff add --summary <text> [--title <text>] [--surface call|phone|meet|talk|chat] [--project <name>] [--ref <ref>] [--operator-input <text>] [--decision <text>] [--follow-up <text>] [--no-brief] [--json]"
  end

  defp call_handoff_ls_usage do
    "jx call handoff ls [--status open|applied|closed] [--surface call|phone|meet|talk|chat] [--project <name>] [--ref <ref>] [-n 20] [--json]"
  end

  defp call_handoff_close_usage do
    "jx call handoff close <handoff-id> [--summary <text>] [--json]"
  end

  defp call_handoff_apply_usage do
    "jx call handoff apply <handoff-id> [--action prompt --ref <ref> --message <text> [--ready|--draft|--prompt-status ready|draft] | --action watch --ref <ref> (--success <pattern>|--blocker <pattern>) [--mode notify|hold|prompt] [--goal <text>] [--prompt <text>] | --action hold --ref <ref> --reason <text>] [--summary <text>] [--json]"
  end

  defp call_handoff_usage do
    "#{call_handoff_add_usage()} | #{call_handoff_ls_usage()} | #{call_handoff_close_usage()} | #{call_handoff_apply_usage()}"
  end

  defp call_usage do
    "#{call_brief_usage()} | #{call_handoff_usage()}"
  end

  defp meet_plugin_usage do
    "jx meet plugin [--json]"
  end

  defp meet_auth_configure_usage do
    "jx meet auth configure --client-id <id> [--profile personal] [--email <email>] [--client-secret-env <env>] [--redirect-uri <uri>] [--scope <scope>] [--artifacts] [--json]"
  end

  defp meet_auth_url_usage do
    "jx meet auth url [--profile personal] [--login-hint <email>] [--scope <scope>] [--json]"
  end

  defp meet_auth_exchange_usage do
    "jx meet auth exchange --code <code> [--profile personal] [--json]"
  end

  defp meet_auth_status_usage do
    "jx meet auth status [--profile personal] [-n 50] [--json]"
  end

  defp meet_auth_usage do
    "#{meet_auth_configure_usage()} | #{meet_auth_url_usage()} | #{meet_auth_exchange_usage()} | #{meet_auth_status_usage()}"
  end

  defp meet_session_create_usage do
    "jx meet session create --meeting <meet-url-or-code> [--title <text>] [--project <name>] [--ref <ref>] [--auth-profile personal] [--chrome-node <debug-url>] [--paired-chrome-node <debug-url>] [--twilio-stream-url <wss-url>] [--twilio-mode none|start|connect] [--twilio-track inbound_track|outbound_track|both_tracks] [--artifact-dir <path>] [--no-handoff] [--json]"
  end

  defp meet_session_ls_usage do
    "jx meet session ls [--status planned|joining|live|recovered|ended|failed] [--project <name>] [--ref <ref>] [--meeting <meet-url-or-code>] [-n 50] [--json]"
  end

  defp meet_session_plan_usage do
    "jx meet session plan <session-id> [--json]"
  end

  defp meet_session_join_usage do
    "jx meet session join <session-id> [--runner browser-agent|chrome-cdp] [--browser-agent-command <cmd>] [--debug-url <url>] [--launch] [--chrome-bin <path>] [--profile-dir <path>] [--no-click] [--no-mute] [--no-camera-off] [--json]"
  end

  defp meet_session_usage do
    "#{meet_session_create_usage()} | #{meet_session_ls_usage()} | #{meet_session_plan_usage()} | #{meet_session_join_usage()}"
  end

  defp meet_realtime_plan_usage do
    "jx meet realtime plan <session-id> [--provider browser-agent|openai-realtime|gemini-live] [--audio-bridge browser-agent|twilio|command] [--browser-agent-command <cmd>] [--audio-ingress-command <cmd>] [--audio-egress-command <cmd>] [--json]"
  end

  defp meet_realtime_start_usage do
    "jx meet realtime start <session-id> [--provider browser-agent|openai-realtime|gemini-live] [--audio-bridge browser-agent|twilio|command] [--browser-agent-command <cmd>] [--audio-ingress-command <cmd>] [--audio-egress-command <cmd>] [--live] [--approve-audio-capture] [--approve-speech-output] [--approve-notes-or-transcription] [--json]"
  end

  defp meet_realtime_watch_usage do
    "jx meet realtime watch <session-id> [--browser-agent-command <cmd> | --caption-file <path> | --chat-file <path>] [--consult-command <cmd>] [--iterations <n>] [--interval-ms <ms>] [--min-chars <n>] [--speak] [--speech-output-command <cmd>] [--json]"
  end

  defp meet_realtime_consult_usage do
    "jx meet realtime consult <session-id> --transcript <text> [--summary <text>] [--title <text>] [--decision <text>] [--follow-up <text>] [--json]"
  end

  defp meet_realtime_usage do
    "#{meet_realtime_plan_usage()} | #{meet_realtime_start_usage()} | #{meet_realtime_watch_usage()} | #{meet_realtime_consult_usage()}"
  end

  defp meet_recover_usage do
    "jx meet recover (--debug-url <url> | --targets-json <path>) [--paired-debug-url <url> | --paired-targets-json <path>] [--meeting <meet-url-or-code>] [--project <name>] [--ref <ref>] [--dry-run] [--no-handoff] [--json]"
  end

  defp meet_sync_usage do
    "jx meet sync <session-id> [--json]"
  end

  defp meet_export_usage do
    "jx meet export <session-id> [--dir <path>] [--format all|json|markdown|attendance-csv|twiml] [--json]"
  end

  defp meet_usage do
    "#{meet_plugin_usage()} | #{meet_auth_usage()} | #{meet_session_usage()} | #{meet_realtime_usage()} | #{meet_recover_usage()} | #{meet_sync_usage()} | #{meet_export_usage()}"
  end

  defp delegate_create_usage do
    "jx delegate create --title <text> --brief <text> [--project <name>] [--ref <ref>] [--owner <name>] [--agent worker|explorer|verifier|codex|claude|opencode|human] [--priority 0] [--context <text>] [--constraint <text>] [--acceptance <text>] [--verify <text>] [--write <path>] [--forbid <path>] [--json]"
  end

  defp delegate_ls_usage do
    "jx delegate ls [--status queued|running|blocked|completed|cancelled|failed] [--project <name>] [--ref <ref>] [--owner <name>] [-n 20] [--json]"
  end

  defp delegate_reviews_usage do
    "jx delegate reviews [--integration pending|accepted|revision_requested|rejected|held|all] [--decision accept|revise|reject|hold] [--project <name>] [--ref <ref>] [-n 20] [--json]"
  end

  defp delegate_timing_usage do
    "jx delegate timing [--project <name>] [--ref <ref>] [--agent worker|explorer|verifier|codex|claude|opencode|human] [--target-parallel 3] [-n 50] [--json]"
  end

  defp delegate_brief_usage do
    "jx delegate brief <delegation-id> [--json]"
  end

  defp delegate_lint_usage do
    "jx delegate lint <delegation-id> [--json]"
  end

  defp delegate_review_usage do
    "jx delegate review <delegation-id> [--json]"
  end

  defp delegate_decide_usage do
    "jx delegate decide <delegation-id> --decision accept|revise|reject|hold [--summary <text>] [--reviewer <name>] [--json]"
  end

  defp delegate_evidence_usage do
    "jx delegate evidence <delegation-id> --command <cmd> --cwd <path> --exit <code> [--kind focused|full|failed-only|smoke|lint|format|ci|manual] [--output <text>] [--artifact <path>] [--risk <text>] [--json]"
  end

  defp delegate_start_usage do
    "jx delegate start <delegation-id> [--owner <name>] [--summary <text>] [--json]"
  end

  defp delegate_complete_usage do
    "jx delegate complete <delegation-id> [--summary <text>] [--verify <text>] [--artifact <text>] [--risk <text>] [--evidence-command <cmd> --evidence-cwd <path> --evidence-exit <code> [--evidence-kind <kind>] [--evidence-output <text>]] [--json]"
  end

  defp delegate_terminal_usage(action) do
    "jx delegate #{action} <delegation-id> [--summary <text>] [--json]"
  end

  defp delegate_usage do
    [
      delegate_create_usage(),
      delegate_ls_usage(),
      delegate_reviews_usage(),
      delegate_timing_usage(),
      delegate_brief_usage(),
      delegate_lint_usage(),
      delegate_review_usage(),
      delegate_decide_usage(),
      delegate_evidence_usage(),
      delegate_start_usage(),
      delegate_complete_usage(),
      delegate_terminal_usage("block"),
      delegate_terminal_usage("fail"),
      delegate_terminal_usage("cancel")
    ]
    |> Enum.join(" | ")
  end

  defp orchestrator_usage do
    "jx orchestrator start|status|stop|logs|health|heartbeats|inbox|review <ref>|decide <ref> [--prompt <text> --ready|--draft | --hold <reason> | --clear | --ignore | --protect | --managed] [--dry-run] [--session #{OrchestratorDaemon.default_session_name()}] [--server #{Tmux.managed_server()}] [--log <path>] [--json]"
  end

  defp modes_usage do
    "jx modes [<mode>|playbook <mode>] [--json]"
  end

  defp next_usage do
    "jx next [--host <host>] [--project <name>] [--managed] [--all-processes] [--type <type>] [--ssh-target <target>] [--work-state <state>] [--control managed|ignored|protected|uncontrolled] [--no-observe] [--lines 80] [--scan-limit 100] [-n 5] [--json]"
  end

  defp wake_usage do
    [
      wake_immediate_usage(),
      wake_add_usage(),
      wake_ls_usage(),
      wake_run_due_usage(),
      wake_remove_usage()
    ]
    |> Enum.join(" | ")
  end

  defp wake_immediate_usage do
    "jx wake --message <text> [--project <name>] [--ref <ref>] [--severity info|notice|warning|critical] [--json]"
  end

  defp wake_add_usage do
    "jx wake add --message <text> (--at <iso8601>|--in <duration>|--every <duration>) [--name <name>] [--project <name>] [--ref <ref>] [--severity info|notice|warning|critical] [--json]"
  end

  defp wake_ls_usage do
    "jx wake ls [--status active|disabled|completed|cancelled] [--project <name>] [--ref <ref>] [-n 50] [--json]"
  end

  defp wake_run_due_usage do
    "jx wake run-due [--limit 20] [--json]"
  end

  defp wake_remove_usage do
    "jx wake remove <trigger-id> [--json]"
  end

  defp task_send_usage do
    "jx task send <task-id> \"<message>\" [--window 0] [--pane 0] [--no-enter]"
  end

  defp orchestrator_decide_attrs(opts) do
    actions =
      [
        prompt: opts[:prompt],
        hold: opts[:hold],
        clear: opts[:clear],
        ignore: opts[:ignore],
        protect: opts[:protect],
        managed: opts[:managed]
      ]
      |> Enum.filter(fn
        {_action, value} when is_binary(value) -> String.trim(value) != ""
        {_action, value} -> value == true
      end)

    cond do
      length(actions) != 1 ->
        {:error,
         "choose exactly one decision action: --prompt, --hold, --clear, --ignore, --protect, or --managed"}

      opts[:ready] && opts[:draft] ->
        {:error, "use either --ready or --draft, not both"}

      true ->
        {action, value} = hd(actions)
        prompt_status = if opts[:draft], do: "draft", else: "ready"

        attrs =
          case action do
            :prompt ->
              %{action: "prompt", prompt: value, prompt_status: prompt_status}

            :hold ->
              %{action: "hold", reason: value}

            action when action in [:clear, :ignore, :protect, :managed] ->
              %{action: Atom.to_string(action)}
          end

        attrs =
          if opts[:note] do
            Map.put(attrs, :notes, opts[:note])
          else
            attrs
          end

        {:ok, attrs}
    end
  end

  defp orchestrator_daemon_opts(opts, overrides) do
    [
      session_name: opts[:session],
      tmux_server: overrides[:server],
      log_path: opts[:log],
      db_path: overrides[:db_path],
      dry_run: opts[:dry_run] || false,
      consumer: opts[:consumer],
      host_name: opts[:host],
      all_tmux: !opts[:managed],
      all_processes: opts[:all_processes] || false,
      type: opts[:type],
      ssh_target: opts[:ssh_target],
      work_state: opts[:work_state],
      control_mode: opts[:control],
      prompt_status: opts[:prompt_status],
      observe: Keyword.get(opts, :observe, true),
      lines: overrides[:lines],
      scan_limit: overrides[:scan_limit],
      queue_limit: overrides[:queue_limit],
      event_limit: overrides[:event_limit],
      decision_limit: overrides[:decision_limit],
      min_observe_age_seconds: overrides[:min_observe_age_seconds],
      interval_ms: overrides[:interval_ms],
      execute: Keyword.get(opts, :execute, true),
      yes: Keyword.get(opts, :yes, true),
      ack: Keyword.get(opts, :ack, true),
      auto_plan: Keyword.get(opts, :auto_plan, true),
      enter: !opts[:no_enter],
      replace: opts[:replace] || false
    ]
  end

  defp print_orchestrator_daemon_status(status, opts) do
    if opts[:json] do
      print_json(status)
    else
      state = if status.running, do: "running", else: "stopped"

      IO.puts("orchestrator #{state}")
      IO.puts("session: #{status.session_name}")
      IO.puts("server: #{status.tmux_server}")
      IO.puts("log: #{status.log_path}")

      if status[:command], do: IO.puts("command: #{status.command}")
      if status[:pane_pid], do: IO.puts("pid: #{status.pane_pid}")
      if status[:current_path], do: IO.puts("path: #{status.current_path}")
    end
  end

  defp print_orchestrator_inbox(inbox, opts) do
    if opts[:json] do
      print_json(json_orchestrator_inbox(inbox))
    else
      IO.puts("orchestrator inbox")
      IO.puts("generated: #{format_time(inbox.generated_at)}")

      print_inbox_section("needs judgment", inbox.sections.needs_judgment)
      print_inbox_delegation_reviews(Map.get(inbox.sections, :delegation_reviews, []))
      print_recovery_recommendations(Map.get(inbox.sections, :recovery, %{}))
      print_inbox_suggestions(inbox.sections.suggestions)
      print_inbox_section("ready / chambered", inbox.sections.ready)
      print_inbox_section("awaiting observation", inbox.sections.awaiting_observation)
      print_inbox_section("recently completed", inbox.sections.recently_completed)

      IO.puts("")
      print_summary_counts("observation refresh", inbox.observation_refresh)

      unless inbox.errors == [] do
        IO.puts("")
        print_summary_errors(inbox.errors)
      end
    end
  end

  defp print_inbox_section(_title, []), do: :ok

  defp print_inbox_section(title, items) do
    IO.puts("")
    IO.puts(title)

    rows =
      Enum.map(items, fn item ->
        [
          item.ref,
          item.project,
          item.state,
          item.prompt_status,
          item.work_state,
          truncate(item.next_step, 32),
          truncate(item.actual, 72)
        ]
      end)

    print_table(["REF", "PROJECT", "STATE", "PROMPT", "WORK", "NEXT", "ACTUAL"], rows)
  end

  defp print_inbox_delegation_reviews([]), do: :ok

  defp print_inbox_delegation_reviews(reviews) do
    IO.puts("")
    IO.puts("delegation reviews")

    rows =
      Enum.map(reviews, fn review ->
        [
          Map.get(review, :delegation_id, ""),
          Map.get(review, :decision, ""),
          Map.get(review, :ref, ""),
          truncate(Map.get(review, :project, ""), 24),
          truncate(Map.get(review, :title, ""), 36),
          truncate(Map.get(review, :summary, ""), 72)
        ]
      end)

    print_table(["ID", "DECISION", "REF", "PROJECT", "TITLE", "SUMMARY"], rows)
  end

  defp print_recovery_plan(recovery, opts) do
    if opts[:json] do
      print_json(recovery)
    else
      IO.puts("session recovery")
      IO.puts("generated: #{format_time(recovery.generated_at)}")
      IO.puts("status: #{recovery.status}")
      print_summary_counts("counts", recovery.counts)
      print_recovery_recommendations(recovery)
    end
  end

  defp print_recovery_recommendations(%{recommendations: []}), do: :ok

  defp print_recovery_recommendations(%{recommendations: recommendations}) do
    IO.puts("")
    IO.puts("recovery recommendations")

    rows =
      Enum.map(recommendations, fn recommendation ->
        [
          recommendation.action,
          recommendation.safety,
          recommendation.ref,
          truncate(recommendation.target, 40),
          truncate(recommendation.reason, 72),
          truncate(Enum.join(recommendation.evidence, "; "), 72)
        ]
      end)

    print_table(["ACTION", "SAFETY", "REF", "TARGET", "REASON", "EVIDENCE"], rows)
  end

  defp print_recovery_recommendations(_recovery), do: :ok

  defp print_inbox_suggestions([]), do: :ok

  defp print_inbox_suggestions(suggestions) do
    IO.puts("")
    IO.puts("planner suggestions")

    rows =
      Enum.map(suggestions, fn suggestion ->
        [
          suggestion.ref,
          suggestion.project,
          suggestion.safety,
          suggestion.prompt_status,
          truncate(suggestion.reason, 40),
          truncate(suggestion.prompt, 96)
        ]
      end)

    print_table(["REF", "PROJECT", "SAFETY", "PROMPT", "REASON", "PLAN"], rows)
  end

  defp print_orchestrator_review(review, opts) do
    if opts[:json] do
      print_json(json_orchestrator_review(review))
    else
      profile = review.profile
      recommendation = review.recommendation

      IO.puts("orchestrator review #{review.ref}")
      IO.puts("generated: #{format_time(review.generated_at)}")
      IO.puts("project: #{get_in(profile, [:session, :project]) || ""}")
      IO.puts("state: #{get_in(profile, [:comparison, :state]) || ""}")
      IO.puts("prompt: #{get_in(profile, [:next_prompt, :status]) || ""}")
      IO.puts("work: #{get_in(profile, [:actual, :work_state]) || ""}")
      IO.puts("actual: #{get_in(profile, [:comparison, :actual_summary]) || ""}")

      if review.latest_observation do
        IO.puts("")
        IO.puts("latest observation")
        print_summary_counts("observation", review.latest_observation)
      end

      IO.puts("")
      IO.puts("recommendation")
      IO.puts("type: #{recommendation.type}")
      IO.puts("safety: #{recommendation.safety}")
      IO.puts("reason: #{recommendation.reason}")

      if String.trim(recommendation.prompt || "") != "" do
        IO.puts("")
        IO.puts("prompt")
        IO.puts(recommendation.prompt)
      end

      print_review_evidence(recommendation.evidence || [])
      print_review_commands(review.commands)

      unless review.errors == [] do
        IO.puts("")
        print_summary_errors(review.errors)
      end
    end
  end

  defp print_review_evidence([]), do: :ok

  defp print_review_evidence(evidence) do
    IO.puts("")
    IO.puts("evidence")
    Enum.each(evidence, &IO.puts("- #{&1}"))
  end

  defp print_review_commands([]), do: :ok

  defp print_review_commands(commands) do
    IO.puts("")
    IO.puts("commands")

    rows =
      Enum.map(commands, fn command ->
        [command.action, command.command]
      end)

    print_table(["ACTION", "COMMAND"], rows)
  end

  defp print_orchestrator_decision(result, opts) do
    if opts[:json] do
      print_json(json_orchestrator_decision(result))
    else
      IO.puts("#{result.result_summary}: #{result.ref}")
    end
  end

  defp run_tui_interactive(opts, state) do
    with {:ok, snapshot} <- TUI.snapshot(opts) do
      selected =
        clamp_tui_selection(Map.get(snapshot, :agenda, []), Keyword.get(state, :selected, 0))

      state = Keyword.put(state, :selected, selected)

      if state[:clear], do: clear_screen()
      print_tui_snapshot(snapshot, json: false)
      print_tui_steering(snapshot, state)

      case read_tui_command() do
        nil -> :ok
        command -> handle_tui_command(command, opts, snapshot, state)
      end
    end
  end

  defp run_tui_watch(opts, iterations, interval_ms, print_opts) do
    tui_watch_loop(opts, iterations, interval_ms, print_opts, 1)
  end

  defp tui_watch_loop(_opts, iterations, _interval_ms, _print_opts, iteration)
       when iterations > 0 and iteration > iterations,
       do: :ok

  defp tui_watch_loop(opts, iterations, interval_ms, print_opts, iteration) do
    with {:ok, snapshot} <- TUI.snapshot(opts) do
      if print_opts[:clear], do: clear_screen()
      print_tui_snapshot(snapshot, print_opts)

      if iterations == 0 or iteration < iterations do
        Process.sleep(interval_ms)
        tui_watch_loop(opts, iterations, interval_ms, print_opts, iteration + 1)
      else
        :ok
      end
    end
  end

  defp clear_screen do
    IO.write("\e[2J\e[H")
  end

  defp print_tui_steering(snapshot, state) do
    agenda = Map.get(snapshot, :agenda, [])
    selected = Keyword.get(state, :selected, 0)

    IO.puts("")
    IO.puts("STEER")
    IO.puts(tui_selection_text(agenda, selected))
    IO.puts("j/k move | 1-9 select | enter/r refresh | ? help | q quit")
    IO.puts("a ack notification | e ack inbox | m manage | i ignore | p protect | u unmark")
    IO.puts("c capture | d draft prompt | s send confirmed prompt")

    if text_present?(Keyword.get(state, :message, "")) do
      IO.puts("status: #{Keyword.fetch!(state, :message)}")
    end
  end

  defp tui_selection_text([], _selected), do: "selected: none"

  defp tui_selection_text(agenda, selected) do
    item = Enum.at(agenda, selected) || List.first(agenda)

    "selected [#{selected + 1}/#{length(agenda)}] #{tui_item_target(item)} #{truncate(Map.get(item, :label, ""), 96)}"
  end

  defp read_tui_command do
    case IO.gets("tui> ") do
      nil -> nil
      input -> input |> String.trim() |> String.downcase()
    end
  end

  defp handle_tui_command(command, opts, _snapshot, state)
       when command in ["", "r", "refresh"] do
    run_tui_interactive(opts, Keyword.delete(state, :message))
  end

  defp handle_tui_command(command, _opts, _snapshot, _state)
       when command in ["q", "quit", "exit"],
       do: :ok

  defp handle_tui_command(command, opts, _snapshot, state)
       when command in ["?", "h", "help"] do
    print_tui_interactive_help()
    pause_tui()
    run_tui_interactive(opts, Keyword.delete(state, :message))
  end

  defp handle_tui_command(command, opts, snapshot, state)
       when command in ["j", "down"] do
    agenda = Map.get(snapshot, :agenda, [])
    selected = clamp_tui_selection(agenda, Keyword.get(state, :selected, 0) + 1)

    run_tui_interactive(
      opts,
      state |> Keyword.put(:selected, selected) |> Keyword.delete(:message)
    )
  end

  defp handle_tui_command(command, opts, snapshot, state)
       when command in ["k", "up"] do
    agenda = Map.get(snapshot, :agenda, [])
    selected = clamp_tui_selection(agenda, Keyword.get(state, :selected, 0) - 1)

    run_tui_interactive(
      opts,
      state |> Keyword.put(:selected, selected) |> Keyword.delete(:message)
    )
  end

  defp handle_tui_command("a", opts, snapshot, state) do
    selected_tui_item(snapshot, state)
    |> tui_ack_notification(opts, state)
  end

  defp handle_tui_command("e", opts, snapshot, state) do
    monitor = Map.get(snapshot, :monitor, %{})
    latest_event_id = Map.get(monitor, :latest_event_id, 0)
    consumer = Map.get(monitor, :consumer, TUI.default_consumer())

    cond do
      latest_event_id <= 0 ->
        rerender_tui(opts, state, "no monitor events to acknowledge")

      confirm_tui?("Acknowledge #{consumer} inbox through event #{latest_event_id}?") ->
        case Workspace.acknowledge_monitor_events(consumer: consumer, to_id: latest_event_id) do
          {:ok, cursor} ->
            rerender_tui(
              opts,
              state,
              "acknowledged #{consumer} through event #{cursor.last_event_id}"
            )

          {:error, reason} ->
            rerender_tui(opts, state, "ack failed: #{format_error(reason)}")
        end

      true ->
        rerender_tui(opts, state, "ack cancelled")
    end
  end

  defp handle_tui_command(command, opts, snapshot, state)
       when command in ["m", "manage", "managed"] do
    selected_tui_item(snapshot, state)
    |> tui_mark_selected("managed", opts, state)
  end

  defp handle_tui_command(command, opts, snapshot, state)
       when command in ["i", "ignore", "ignored"] do
    selected_tui_item(snapshot, state)
    |> tui_mark_selected("ignored", opts, state)
  end

  defp handle_tui_command(command, opts, snapshot, state)
       when command in ["p", "protect", "protected"] do
    selected_tui_item(snapshot, state)
    |> tui_mark_selected("protected", opts, state)
  end

  defp handle_tui_command(command, opts, snapshot, state)
       when command in ["u", "unmark"] do
    selected_tui_item(snapshot, state)
    |> tui_unmark_selected(opts, state)
  end

  defp handle_tui_command(command, opts, snapshot, state)
       when command in ["c", "capture"] do
    selected_tui_item(snapshot, state)
    |> tui_capture_selected(opts, state)
  end

  defp handle_tui_command(command, opts, snapshot, state)
       when command in ["d", "draft"] do
    selected_tui_item(snapshot, state)
    |> tui_draft_prompt(opts, state)
  end

  defp handle_tui_command(command, opts, snapshot, state)
       when command in ["s", "send", "steer"] do
    selected_tui_item(snapshot, state)
    |> tui_send_prompt(opts, state)
  end

  defp handle_tui_command(command, opts, snapshot, state) do
    case Integer.parse(command) do
      {index, ""} ->
        agenda = Map.get(snapshot, :agenda, [])
        selected = clamp_tui_selection(agenda, index - 1)

        run_tui_interactive(
          opts,
          state |> Keyword.put(:selected, selected) |> Keyword.delete(:message)
        )

      _other ->
        rerender_tui(opts, state, "unknown command: #{command}")
    end
  end

  defp print_tui_interactive_help do
    IO.puts("")
    IO.puts("interactive commands")
    IO.puts("  j/k or number  move selection")
    IO.puts("  r or enter      refresh")
    IO.puts("  a               acknowledge selected notification")
    IO.puts("  e               acknowledge monitor inbox through latest event")
    IO.puts("  m/i/p/u         mark selected ref managed/ignored/protected or unmark")
    IO.puts("  c               capture selected ref")
    IO.puts("  d               save a draft steering prompt on the selected ref")
    IO.puts("  s               send a confirmed steering prompt to the selected ref")
    IO.puts("  q               quit")
  end

  defp tui_ack_notification(nil, opts, state), do: rerender_tui(opts, state, "no selected item")

  defp tui_ack_notification(item, opts, state) do
    id = Map.get(item, :id, "")

    cond do
      Map.get(item, :kind, "") != "notification" ->
        rerender_tui(opts, state, "selected item is not a notification")

      id in [nil, ""] ->
        rerender_tui(opts, state, "selected notification has no id")

      confirm_tui?("Acknowledge notification #{id}?") ->
        case Workspace.acknowledge_notifications(notification_id: id) do
          {:ok, notification} ->
            rerender_tui(opts, state, "acknowledged #{notification.notification_id}")

          {:error, reason} ->
            rerender_tui(opts, state, "ack failed: #{format_error(reason)}")
        end

      true ->
        rerender_tui(opts, state, "ack cancelled")
    end
  end

  defp tui_mark_selected(nil, _mode, opts, state),
    do: rerender_tui(opts, state, "no selected item")

  defp tui_mark_selected(item, mode, opts, state) do
    with {:ok, ref} <- tui_selected_ref(item) do
      if confirm_tui?("Mark #{ref} #{mode}?") do
        case Workspace.set_session_control(ref, mode,
               project: Map.get(item, :project, ""),
               note: "steered from tui"
             ) do
          {:ok, control} ->
            rerender_tui(opts, state, "session #{control.ref} marked #{control.mode}")

          {:error, reason} ->
            rerender_tui(opts, state, "mark failed: #{format_error(reason)}")
        end
      else
        rerender_tui(opts, state, "mark cancelled")
      end
    else
      {:error, reason} -> rerender_tui(opts, state, reason)
    end
  end

  defp tui_unmark_selected(nil, opts, state), do: rerender_tui(opts, state, "no selected item")

  defp tui_unmark_selected(item, opts, state) do
    with {:ok, ref} <- tui_selected_ref(item) do
      if confirm_tui?("Unmark #{ref}?") do
        case Workspace.clear_session_control(ref) do
          {:ok, _control} -> rerender_tui(opts, state, "session #{ref} unmarked")
          {:error, reason} -> rerender_tui(opts, state, "unmark failed: #{format_error(reason)}")
        end
      else
        rerender_tui(opts, state, "unmark cancelled")
      end
    else
      {:error, reason} -> rerender_tui(opts, state, reason)
    end
  end

  defp tui_capture_selected(nil, opts, state), do: rerender_tui(opts, state, "no selected item")

  defp tui_capture_selected(item, opts, state) do
    with {:ok, ref} <- tui_selected_ref(item) do
      case Workspace.capture_session(ref, lines: 80) do
        {:ok, output} ->
          clear_screen()
          IO.puts("CAPTURE #{ref}")
          IO.puts("")
          IO.write(output)
          pause_tui()
          run_tui_interactive(opts, Keyword.delete(state, :message))

        {:error, reason} ->
          rerender_tui(opts, state, "capture failed: #{format_error(reason)}")
      end
    else
      {:error, reason} -> rerender_tui(opts, state, reason)
    end
  end

  defp tui_draft_prompt(nil, opts, state), do: rerender_tui(opts, state, "no selected item")

  defp tui_draft_prompt(item, opts, state) do
    with {:ok, ref} <- tui_selected_ref(item),
         {:ok, prompt} <- read_tui_prompt("draft prompt for #{ref}") do
      case Workspace.set_session_profile(ref, %{
             next_prompt: prompt,
             prompt_status: "draft",
             last_seen_at: DateTime.utc_now()
           }) do
        {:ok, _profile} -> rerender_tui(opts, state, "draft saved for #{ref}")
        {:error, reason} -> rerender_tui(opts, state, "draft failed: #{format_error(reason)}")
      end
    else
      {:error, reason} -> rerender_tui(opts, state, reason)
    end
  end

  defp tui_send_prompt(nil, opts, state), do: rerender_tui(opts, state, "no selected item")

  defp tui_send_prompt(item, opts, state) do
    with {:ok, ref} <- tui_selected_ref(item),
         {:ok, prompt} <- read_tui_prompt("send prompt to #{ref}") do
      if confirm_tui?("Send this prompt to #{ref}? #{truncate(prompt, 80)}") do
        case Workspace.send_session_prompt(ref, prompt, enter: true) do
          {:ok, directive} ->
            rerender_tui(opts, state, "sent directive #{directive.directive_id} to #{ref}")

          {:error, reason} ->
            rerender_tui(opts, state, "send failed: #{format_error(reason)}")
        end
      else
        rerender_tui(opts, state, "send cancelled")
      end
    else
      {:error, reason} -> rerender_tui(opts, state, reason)
    end
  end

  defp selected_tui_item(snapshot, state) do
    snapshot
    |> Map.get(:agenda, [])
    |> Enum.at(Keyword.get(state, :selected, 0))
  end

  defp tui_selected_ref(item) do
    case Map.get(item, :ref, "") do
      ref when ref in [nil, "", "orchestrator"] -> {:error, "selected item has no session ref"}
      ref -> {:ok, ref}
    end
  end

  defp tui_item_target(item) do
    [
      Map.get(item, :ref, ""),
      Map.get(item, :project, "")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> Map.get(item, :kind, "")
      parts -> Enum.join(parts, " ")
    end
  end

  defp read_tui_prompt(label) do
    case IO.gets("#{label}> ") do
      nil ->
        {:error, "prompt cancelled"}

      input ->
        prompt = String.trim(input)

        if prompt == "" do
          {:error, "prompt cannot be empty"}
        else
          {:ok, prompt}
        end
    end
  end

  defp confirm_tui?(question) do
    case IO.gets("#{question} [y/N] ") do
      nil ->
        false

      input ->
        answer = input |> String.trim() |> String.downcase()
        answer in ["y", "yes"]
    end
  end

  defp pause_tui do
    _input = IO.gets("")
    :ok
  end

  defp rerender_tui(opts, state, message) do
    run_tui_interactive(opts, Keyword.put(state, :message, message))
  end

  defp clamp_tui_selection([], _selected), do: 0

  defp clamp_tui_selection(agenda, selected) do
    selected
    |> max(0)
    |> min(length(agenda) - 1)
  end

  defp run_orchestrate("step", opts, _iterations, _interval_ms, print_opts) do
    with {:ok, report} <- Workspace.orchestrate(opts) do
      print_orchestrate_report(report, print_opts)
      :ok
    end
  end

  defp run_orchestrate(command, opts, iterations, interval_ms, print_opts)
       when command in ["run", "start"] do
    orchestrate_loop(opts, iterations, interval_ms, print_opts, 1)
  end

  defp orchestrate_loop(_opts, iterations, _interval_ms, _print_opts, iteration)
       when iterations > 0 and iteration > iterations,
       do: :ok

  defp orchestrate_loop(opts, 0, interval_ms, print_opts, iteration) do
    case orchestrate_iteration(opts, print_opts, iteration) do
      :ok ->
        Process.sleep(interval_ms)
        orchestrate_loop(opts, 0, interval_ms, print_opts, iteration + 1)

      {:error, reason} ->
        print_orchestrate_loop_error(reason, print_opts)
        record_orchestrate_loop_error(opts, interval_ms, reason)
        Process.sleep(interval_ms)
        orchestrate_loop(opts, 0, interval_ms, print_opts, iteration + 1)
    end
  end

  defp orchestrate_loop(opts, iterations, interval_ms, print_opts, iteration) do
    with :ok <- orchestrate_iteration(opts, print_opts, iteration) do
      if iterations == 0 or iteration < iterations do
        Process.sleep(interval_ms)
        orchestrate_loop(opts, iterations, interval_ms, print_opts, iteration + 1)
      else
        :ok
      end
    end
  end

  defp orchestrate_iteration(opts, print_opts, iteration) do
    with {:ok, report} <- orchestrate_fun().(opts) do
      IO.puts("orchestrate iteration #{iteration}")
      print_orchestrate_report(report, print_opts)
      :ok
    end
  rescue
    error -> {:error, {:exception, error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:caught, kind, reason, __STACKTRACE__}}
  end

  defp print_orchestrate_loop_error(reason, opts) do
    error = orchestrate_loop_error_message(reason)

    if opts[:json] do
      print_json(%{generated_at: DateTime.utc_now() |> DateTime.to_iso8601(), error: error})
    else
      IO.puts(:stderr, "orchestrate iteration failed: #{error}")
    end
  end

  defp record_orchestrate_loop_error(opts, interval_ms, reason) do
    now = DateTime.utc_now()
    error = orchestrate_loop_error_message(reason)

    %{
      daemon_key: Keyword.get(opts, :daemon_key) || orchestrate_consumer(opts),
      consumer: orchestrate_consumer(opts),
      session_name: Keyword.get(opts, :session_name) || "",
      status: "error",
      mode: orchestrate_loop_mode(opts),
      last_scan_at: now,
      last_decision_at: nil,
      last_error: truncate(error, 500),
      next_wake_at: DateTime.add(now, div(interval_ms, 1_000), :second),
      scan_snapshot: Jason.encode!(%{error: error})
    }
    |> OrchestratorHeartbeats.upsert()

    :ok
  rescue
    _error -> :ok
  end

  defp orchestrate_consumer(opts) do
    Keyword.get(opts, :consumer) || MonitorEvents.default_consumer()
  end

  defp orchestrate_loop_mode(opts) do
    execute? = Keyword.get(opts, :execute, false)
    ack? = Keyword.get(opts, :ack, execute?)

    case {execute?, ack?} do
      {true, true} -> "execute+ack"
      {true, false} -> "execute"
      {false, true} -> "ack"
      {false, false} -> "dry-run"
    end
  end

  defp orchestrate_loop_error_message({:exception, error, stacktrace}) do
    Exception.format(:error, error, stacktrace) |> String.trim()
  end

  defp orchestrate_loop_error_message({:caught, kind, reason, stacktrace}) do
    Exception.format(kind, reason, stacktrace) |> String.trim()
  end

  defp orchestrate_loop_error_message(reason), do: format_error(reason)

  defp orchestrate_fun do
    Process.get(:jx_cli_orchestrate_fun, &Workspace.orchestrate/1)
  end

  defp run_monitor("scan", opts, _iterations, _interval_ms, print_opts) do
    with {:ok, scan} <- Workspace.monitor_scan(opts) do
      print_monitor_scan(scan, print_opts)
      :ok
    end
  end

  defp run_monitor(command, opts, iterations, interval_ms, print_opts)
       when command in ["run", "start"] do
    monitor_loop(opts, iterations, interval_ms, print_opts, 1)
  end

  defp monitor_loop(_opts, iterations, _interval_ms, _print_opts, iteration)
       when iterations > 0 and iteration > iterations do
    :ok
  end

  defp monitor_loop(opts, iterations, interval_ms, print_opts, iteration) do
    with {:ok, scan} <- Workspace.monitor_scan(opts) do
      IO.puts("monitor iteration #{iteration}")
      print_monitor_scan(scan, print_opts)

      if iterations == 0 or iteration < iterations do
        Process.sleep(interval_ms)
        monitor_loop(opts, iterations, interval_ms, print_opts, iteration + 1)
      else
        :ok
      end
    end
  end

  defp print_repo_doctor_report(report, json: true), do: print_json(%{repo_doctor: report})

  defp print_repo_doctor_report(report, json: false) do
    IO.puts("repo doctor #{report.project}")
    IO.puts("base: #{report.base_branch}")
    IO.puts("promote-to: #{report.promote_branch}")
    print_summary_counts("summary", report.summary)

    unless report.warnings == [] do
      IO.puts("warnings: #{Enum.join(report.warnings, "; ")}")
    end

    Enum.each(report.instances, fn instance ->
      IO.puts("")
      IO.puts("#{instance.host} #{instance.repo_path}")
      IO.puts("  status: #{instance.status}")
      IO.puts("  reconciled: #{instance.reconciliation_status}")
      IO.puts("  trusted: #{instance.trust_status}")
      IO.puts("  confidence: #{instance.confidence}")
      IO.puts("  auth: #{instance.auth_status}")
      IO.puts("  branch: #{instance.branch}")
      IO.puts("  head: #{truncate(instance.head, 12)}")

      IO.puts(
        "  canonical: #{truncate(instance.canonical_ref, 12)} (#{instance.canonical_source})"
      )

      IO.puts("  drift: #{format_repo_drift(instance.drift)}")
      IO.puts("  remote: #{instance.remote} #{instance.remote_url}")

      Enum.each(instance.checks, fn check ->
        IO.puts("  #{doctor_status(check.status)} #{check.name}#{doctor_detail(check.detail)}")
      end)
    end)
  end

  defp print_repo_gate_report(report, json: true), do: print_json(%{repo_gate: report})

  defp print_repo_gate_report(report, json: false) do
    IO.puts("Repo: #{report.project}")
    IO.puts("Promotion eligible: #{yes_no(report.eligible)}")
    IO.puts("Status: #{report.status}")
    print_repo_gate_list("Reasons", report.reasons)
    print_repo_gate_list("Required fixes", report.required_fixes)

    if length(report.instances) > 1 do
      IO.puts("")
      IO.puts("Instances:")

      Enum.each(report.instances, fn instance ->
        reason_text =
          case instance.reasons do
            [] -> "none"
            reasons -> Enum.join(reasons, ", ")
          end

        IO.puts("- #{instance.host} #{instance.status}: #{reason_text}")
      end)
    end
  end

  defp doctor_status(:ok), do: "OK"
  defp doctor_status(:fail), do: "FAIL"
  defp doctor_status(:skip), do: "SKIP"

  defp doctor_detail(nil), do: ""
  defp doctor_detail(""), do: ""
  defp doctor_detail(detail), do: " - #{detail}"

  defp print_repo_gate_list(title, []), do: IO.puts("#{title}:\n- none")

  defp print_repo_gate_list(title, items) do
    IO.puts("#{title}:")
    Enum.each(items, &IO.puts("- #{&1}"))
  end

  defp print_promotion_preflight(report, json: true),
    do: print_json(%{promotion_preflight: report})

  defp print_promotion_preflight(report, json: false) do
    IO.puts("Promotion preflight: #{report.project}")
    IO.puts("From: #{report.source_branch}")
    IO.puts("To: #{report.target_branch}")
    IO.puts("Eligible: #{yes_no(report.eligible)}")
    IO.puts("Status: #{report.status}")
    print_repo_gate_list("Reasons", report.reasons)
    print_repo_gate_list("Required fixes", report.required_fixes)
  end

  defp print_promotion(report, json: true), do: print_json(%{promotion: report})

  defp print_promotion(report, json: false) do
    IO.puts("Promotion: #{report.project}")
    IO.puts("From: #{report.source_branch}")
    IO.puts("To: #{report.target_branch}")
    IO.puts("Status: #{report.status}")
    print_repo_gate_list("Actions", report.actions)
    print_repo_gate_list("Errors", report.errors)
  end

  defp promotion_cli_status(%{status: "promoted"}), do: :ok
  defp promotion_cli_status(%{status: status}), do: {:error, "promotion #{status}"}

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"

  defp format_repo_drift(%{present: false}), do: "none"
  defp format_repo_drift(%{reasons: reasons}), do: Enum.join(reasons, ", ")
  defp format_repo_drift(_drift), do: "unknown"

  defp validate_agent_name(agent_name) do
    if agent_name in AgentRunner.agent_names() do
      :ok
    else
      {:error,
       "unsupported agent #{inspect(agent_name)}; expected one of: #{Enum.join(AgentRunner.agent_names(), ", ")}"}
    end
  end

  defp validate_agent_transport(agent_transport) do
    if agent_transport in AgentRunner.agent_transports() do
      :ok
    else
      {:error,
       "unsupported agent transport #{inspect(agent_transport)}; expected one of: #{Enum.join(AgentRunner.agent_transports(), ", ")}"}
    end
  end

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
    if work_state in JX.SessionStatus.work_states() do
      :ok
    else
      {:error,
       "unsupported work state #{inspect(work_state)}; expected one of: #{Enum.join(JX.SessionStatus.work_states(), ", ")}"}
    end
  end

  defp validate_optional_operation_status(nil), do: :ok

  defp validate_optional_operation_status(status) do
    if status in ~w(executed skipped error) do
      :ok
    else
      {:error,
       "unsupported operation status #{inspect(status)}; expected one of: executed, skipped, error"}
    end
  end

  defp validate_optional_notification_status(nil), do: :ok

  defp validate_optional_notification_status(status) do
    statuses = JX.Notifications.statuses()

    if status in statuses do
      :ok
    else
      {:error,
       "unsupported notification status #{inspect(status)}; expected one of: #{Enum.join(statuses, ", ")}"}
    end
  end

  defp validate_optional_heartbeat_status(nil), do: :ok

  defp validate_optional_heartbeat_status(status) do
    statuses = JX.OrchestratorHeartbeats.statuses()

    if status in statuses do
      :ok
    else
      {:error,
       "unsupported heartbeat status #{inspect(status)}; expected one of: #{Enum.join(statuses, ", ")}"}
    end
  end

  defp validate_manage_policy("conservative"), do: :ok

  defp validate_manage_policy(policy),
    do: {:error, "unsupported manage policy #{inspect(policy)}; expected conservative"}

  defp validate_tui_mode_options(true, true, _json?),
    do: {:error, "jx tui interactive cannot be combined with watch mode"}

  defp validate_tui_mode_options(true, _watch?, true),
    do: {:error, "jx tui interactive cannot be combined with --json"}

  defp validate_tui_mode_options(_interactive?, _watch?, _json?), do: :ok

  defp validate_session_control_mode(mode) do
    if mode in JX.SessionControls.modes() do
      :ok
    else
      {:error,
       "unsupported session control mode #{inspect(mode)}; expected one of: #{Enum.join(JX.SessionControls.modes(), ", ")}"}
    end
  end

  defp validate_optional_session_control_mode(nil), do: :ok
  defp validate_optional_session_control_mode(mode), do: validate_session_control_mode(mode)

  defp validate_optional_work_board_control(nil), do: :ok

  defp validate_optional_work_board_control("uncontrolled"), do: :ok

  defp validate_optional_work_board_control(mode), do: validate_session_control_mode(mode)

  defp validate_optional_dossier_next_action(nil), do: :ok

  defp validate_optional_dossier_next_action(action) do
    actions = JX.SessionDossiers.next_actions()

    if action in actions do
      :ok
    else
      {:error,
       "unsupported dossier next action #{inspect(action)}; expected one of: #{Enum.join(actions, ", ")}"}
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

  defp validate_optional_watch_status(nil), do: :ok

  defp validate_optional_watch_status(status) do
    statuses = JX.SessionWatches.statuses()

    if status in statuses do
      :ok
    else
      {:error,
       "unsupported watch status #{inspect(status)}; expected one of: #{Enum.join(statuses, ", ")}"}
    end
  end

  defp validate_optional_watch_mode(nil), do: :ok

  defp validate_optional_watch_mode(mode) do
    modes = JX.SessionWatches.modes()

    if mode in modes do
      :ok
    else
      {:error,
       "unsupported watch mode #{inspect(mode)}; expected one of: #{Enum.join(modes, ", ")}"}
    end
  end

  defp validate_optional_ci_watch_status(nil), do: :ok

  defp validate_optional_ci_watch_status(status) do
    statuses = JX.CiWatches.statuses()

    if status in statuses do
      :ok
    else
      {:error,
       "unsupported CI watch status #{inspect(status)}; expected one of: #{Enum.join(statuses, ", ")}"}
    end
  end

  defp validate_optional_ci_watch_mode(nil), do: :ok

  defp validate_optional_ci_watch_mode(mode) do
    modes = JX.CiWatches.modes()

    if mode in modes do
      :ok
    else
      {:error,
       "unsupported CI watch mode #{inspect(mode)}; expected one of: #{Enum.join(modes, ", ")}"}
    end
  end

  defp validate_optional_call_handoff_status(nil), do: :ok

  defp validate_optional_call_handoff_status(status) do
    statuses = JX.CallHandoffs.statuses()

    if status in statuses do
      :ok
    else
      {:error,
       "unsupported call handoff status #{inspect(status)}; expected one of: #{Enum.join(statuses, ", ")}"}
    end
  end

  defp validate_optional_call_surface(nil), do: :ok

  defp validate_optional_call_surface(surface) do
    surfaces = JX.CallHandoffs.surfaces()

    if surface in surfaces do
      :ok
    else
      {:error,
       "unsupported call surface #{inspect(surface)}; expected one of: #{Enum.join(surfaces, ", ")}"}
    end
  end

  defp validate_optional_delegation_status(nil), do: :ok

  defp validate_optional_delegation_status(status) do
    statuses = JX.Delegations.statuses()

    if status in statuses do
      :ok
    else
      {:error,
       "unsupported delegation status #{inspect(status)}; expected one of: #{Enum.join(statuses, ", ")}"}
    end
  end

  defp validate_optional_integration_status(nil), do: :ok
  defp validate_optional_integration_status("all"), do: :ok

  defp validate_optional_integration_status(status) do
    statuses = JX.Delegations.integration_statuses()

    if status in statuses do
      :ok
    else
      {:error,
       "unsupported integration status #{inspect(status)}; expected one of: all, #{Enum.join(statuses, ", ")}"}
    end
  end

  defp validate_optional_review_decision(nil), do: :ok
  defp validate_optional_review_decision(decision), do: validate_review_decision(decision)

  defp validate_review_decision(decision) do
    decisions = JX.Delegations.review_decisions()

    if decision in decisions do
      :ok
    else
      {:error,
       "unsupported review decision #{inspect(decision)}; expected one of: #{Enum.join(decisions, ", ")}"}
    end
  end

  defp validate_optional_delegation_agent(nil), do: :ok

  defp validate_optional_delegation_agent(agent_kind) do
    agent_kinds = JX.Delegations.agent_kinds()

    if agent_kind in agent_kinds do
      :ok
    else
      {:error,
       "unsupported delegation agent #{inspect(agent_kind)}; expected one of: #{Enum.join(agent_kinds, ", ")}"}
    end
  end

  defp validate_optional_call_handoff_apply_action(nil), do: :ok

  defp validate_optional_call_handoff_apply_action(action) do
    if action in ~w(prompt watch hold) do
      :ok
    else
      {:error,
       "unsupported handoff apply action #{inspect(action)}; expected prompt, watch, or hold"}
    end
  end

  defp validate_optional_meet_session_status(nil), do: :ok

  defp validate_optional_meet_session_status(status) do
    statuses = JX.GoogleMeet.session_statuses()

    if status in statuses do
      :ok
    else
      {:error,
       "unsupported Meet session status #{inspect(status)}; expected one of: #{Enum.join(statuses, ", ")}"}
    end
  end

  defp validate_optional_meet_join_runner(nil), do: :ok

  defp validate_optional_meet_join_runner(runner) do
    if String.replace(runner, "_", "-") in ["browser-agent", "chrome-cdp"] do
      :ok
    else
      {:error,
       "unsupported Meet join runner #{inspect(runner)}; expected browser-agent or chrome-cdp"}
    end
  end

  defp validate_optional_meet_realtime_provider(nil), do: :ok

  defp validate_optional_meet_realtime_provider(provider) do
    providers = JX.GoogleMeet.realtime_providers()

    if String.replace(provider, "_", "-") in providers do
      :ok
    else
      {:error,
       "unsupported Meet realtime provider #{inspect(provider)}; expected one of: #{Enum.join(providers, ", ")}"}
    end
  end

  defp validate_optional_meet_audio_bridge(nil), do: :ok

  defp validate_optional_meet_audio_bridge(bridge) do
    bridges = JX.GoogleMeet.audio_bridges()

    if String.replace(bridge, "_", "-") in bridges do
      :ok
    else
      {:error,
       "unsupported Meet audio bridge #{inspect(bridge)}; expected one of: #{Enum.join(bridges, ", ")}"}
    end
  end

  defp validate_optional_meet_twilio_mode(nil), do: :ok

  defp validate_optional_meet_twilio_mode(mode) do
    modes = JX.GoogleMeet.twilio_modes()

    if mode in modes do
      :ok
    else
      {:error,
       "unsupported Meet Twilio mode #{inspect(mode)}; expected one of: #{Enum.join(modes, ", ")}"}
    end
  end

  defp validate_optional_meet_twilio_track(nil), do: :ok

  defp validate_optional_meet_twilio_track(track) do
    tracks = JX.GoogleMeet.twilio_tracks()

    if track in tracks do
      :ok
    else
      {:error,
       "unsupported Meet Twilio track #{inspect(track)}; expected one of: #{Enum.join(tracks, ", ")}"}
    end
  end

  defp validate_optional_meet_export_format(nil), do: :ok

  defp validate_optional_meet_export_format(format) do
    formats = JX.GoogleMeet.export_formats()

    if format
       |> String.split(",", trim: true)
       |> Enum.all?(&(&1 in formats)) do
      :ok
    else
      {:error,
       "unsupported Meet export format #{inspect(format)}; expected one of: #{Enum.join(formats, ", ")}"}
    end
  end

  defp validate_meet_recover_source(opts) do
    if text_present?(opts[:debug_url]) or text_present?(opts[:targets_json]) do
      :ok
    else
      {:error, "usage: #{meet_recover_usage()}"}
    end
  end

  defp validate_call_handoff_apply_prompt_status(opts) do
    cond do
      opts[:ready] && opts[:draft] ->
        {:error, "jx call handoff apply accepts either --ready or --draft, not both"}

      opts[:prompt_status] in [nil, "ready", "draft"] ->
        :ok

      true ->
        {:error,
         "unsupported prompt status #{inspect(opts[:prompt_status])}; expected ready or draft"}
    end
  end

  defp call_handoff_apply_attrs(opts) do
    case opts[:action] do
      nil ->
        {:ok, opts[:summary] || ""}

      "prompt" ->
        with {:ok, ref} <- required_option(opts, :ref, call_handoff_apply_usage()),
             {:ok, message} <- required_option(opts, :message, call_handoff_apply_usage()) do
          {:ok,
           %{
             action: "prompt",
             ref: ref,
             message: message,
             prompt_status: call_handoff_prompt_status(opts),
             summary: opts[:summary] || ""
           }}
        end

      "hold" ->
        with {:ok, ref} <- required_option(opts, :ref, call_handoff_apply_usage()),
             {:ok, reason} <- required_option(opts, :reason, call_handoff_apply_usage()) do
          {:ok,
           %{
             action: "hold",
             ref: ref,
             reason: reason,
             summary: opts[:summary] || ""
           }}
        end

      "watch" ->
        with {:ok, ref} <- required_option(opts, :ref, call_handoff_apply_usage()),
             :ok <- validate_watch_patterns(opts[:success], opts[:blocker]) do
          {:ok,
           %{
             action: "watch",
             ref: ref,
             mode: opts[:mode] || "notify",
             goal: opts[:goal] || "",
             success_pattern: opts[:success] || "",
             blocker_pattern: opts[:blocker] || "",
             prompt: opts[:prompt] || "",
             summary: opts[:summary] || ""
           }}
        end
    end
  end

  defp call_handoff_prompt_status(opts) do
    cond do
      opts[:draft] -> "draft"
      opts[:ready] -> "ready"
      opts[:prompt_status] -> opts[:prompt_status]
      true -> "ready"
    end
  end

  defp optional_repeated(opts, key) do
    case Keyword.get_values(opts, key) do
      [] -> nil
      values -> values
    end
  end

  defp maybe_filter_profile(profiles, nil), do: profiles

  defp maybe_filter_profile(profiles, profile_name) do
    Enum.filter(profiles, &(&1.name == profile_name))
  end

  defp optional_meeting_code(nil), do: {:ok, nil}

  defp optional_meeting_code(meeting) do
    case normalize_meeting_for_cli(meeting) do
      {:ok, %{meeting_code: code}} -> {:ok, code}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_meeting_for_cli(meeting) do
    JX.GoogleMeet.normalize_meeting(meeting)
  end

  defp meet_session_attrs(opts) do
    %{
      meeting: opts[:meeting],
      title: opts[:title] || "",
      project: opts[:project] || "",
      ref: opts[:ref] || "",
      auth_profile: opts[:auth_profile] || "personal",
      chrome_node: opts[:chrome_node] || "",
      paired_chrome_node: opts[:paired_chrome_node] || "",
      twilio_stream_url: opts[:twilio_stream_url] || "",
      twilio_mode: opts[:twilio_mode] || if(opts[:twilio_stream_url], do: "start", else: "none"),
      twilio_track: opts[:twilio_track] || "inbound_track",
      twilio_call_sid: opts[:twilio_call_sid] || "",
      websocket_url: opts[:websocket_url] || "",
      artifact_dir: opts[:artifact_dir] || "",
      conference_record: opts[:conference_record] || ""
    }
  end

  defp meet_join_opts(opts) do
    [
      runner: opts[:runner] || "browser-agent",
      browser_agent_command: opts[:browser_agent_command],
      debug_url: opts[:debug_url],
      launch: opts[:launch] || false,
      chrome_bin: opts[:chrome_bin],
      profile_dir: opts[:profile_dir],
      paired_profile_dir: opts[:paired_profile_dir],
      paired: Keyword.get(opts, :paired, true),
      paired_click_join: opts[:paired_click_join] || false,
      click_join: Keyword.get(opts, :click, true),
      mute: Keyword.get(opts, :mute, true),
      camera_off: Keyword.get(opts, :camera_off, true),
      timeout_ms: opts[:timeout_ms] || 30_000,
      settle_ms: opts[:settle_ms] || 2_000,
      poll_ms: opts[:poll_ms] || 1_000
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp meet_realtime_opts(opts) do
    [
      provider: opts[:provider] || "browser-agent",
      audio_bridge: opts[:audio_bridge],
      browser_agent_command: opts[:browser_agent_command],
      audio_ingress_command: opts[:audio_ingress_command],
      audio_egress_command: opts[:audio_egress_command],
      approve_audio_capture: opts[:approve_audio_capture],
      approve_speech_output: opts[:approve_speech_output],
      approve_notes_or_transcription: opts[:approve_notes_or_transcription]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp meet_realtime_attrs(opts) do
    opts
    |> meet_realtime_opts()
    |> Keyword.put(:live, opts[:live] || false)
    |> Map.new()
  end

  defp meet_realtime_watch_opts(opts) do
    [
      browser_agent_command: opts[:browser_agent_command],
      caption_file: opts[:caption_file],
      chat_file: opts[:chat_file],
      consult_command: opts[:consult_command],
      speech_output_command: opts[:speech_output_command],
      iterations: opts[:iterations] || 1,
      interval_ms: opts[:interval_ms] || 1_000,
      min_chars: opts[:min_chars] || 12,
      timeout_ms: opts[:timeout_ms] || 5_000,
      speak: opts[:speak] || false
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp meet_realtime_consult_attrs(opts) do
    %{
      transcript: opts[:transcript] || "",
      summary: opts[:summary] || "",
      title: opts[:title] || "",
      operator_input: opts[:operator_input] || "",
      project: opts[:project] || "",
      ref: opts[:ref] || "",
      decisions: Keyword.get_values(opts, :decision),
      follow_ups: Keyword.get_values(opts, :follow_up)
    }
  end

  defp meet_recover_attrs(opts) do
    meet_session_attrs(opts)
    |> Map.merge(%{
      debug_url: opts[:debug_url] || "",
      paired_debug_url: opts[:paired_debug_url] || "",
      targets_json: opts[:targets_json] || "",
      paired_targets_json: opts[:paired_targets_json] || "",
      handoff: Keyword.get(opts, :handoff, true),
      dry_run: opts[:dry_run] || false
    })
  end

  defp evidence_attrs(opts, usage) do
    with {:ok, command} <- required_option(opts, :command, usage),
         {:ok, cwd} <- required_option(opts, :cwd, usage),
         {:ok, exit_status} <- required_integer_option(opts, :exit, usage) do
      {:ok,
       %{
         command: command,
         cwd: cwd,
         exit_status: exit_status,
         kind: opts[:kind] || "command",
         output_excerpt: opts[:output] || "",
         artifacts: Keyword.get_values(opts, :artifact),
         risks: Keyword.get_values(opts, :risk)
       }}
    end
  end

  defp complete_evidence(opts) do
    if complete_evidence_present?(opts) do
      with {:ok, command} <- required_option(opts, :evidence_command, delegate_complete_usage()),
           {:ok, cwd} <- required_option(opts, :evidence_cwd, delegate_complete_usage()),
           {:ok, exit_status} <-
             required_integer_option(opts, :evidence_exit, delegate_complete_usage()) do
        {:ok,
         [
           %{
             command: command,
             cwd: cwd,
             exit_status: exit_status,
             kind: opts[:evidence_kind] || "command",
             output_excerpt: opts[:evidence_output] || "",
             artifacts: Keyword.get_values(opts, :artifact),
             risks: Keyword.get_values(opts, :risk)
           }
         ]}
      end
    else
      {:ok, []}
    end
  end

  defp complete_evidence_present?(opts) do
    Enum.any?(
      [:evidence_command, :evidence_cwd, :evidence_exit, :evidence_kind, :evidence_output],
      &Keyword.has_key?(opts, &1)
    )
  end

  defp complete_delegation_attrs(opts, evidence) do
    [
      worker_summary: opts[:summary] || "",
      artifacts: Keyword.get_values(opts, :artifact),
      residual_risks: Keyword.get_values(opts, :risk),
      evidence: evidence
    ]
    |> maybe_put_repeated(:verification, opts, :verify)
  end

  defp maybe_put_repeated(attrs, target_key, opts, source_key) do
    if Keyword.has_key?(opts, source_key) do
      Keyword.put(attrs, target_key, Keyword.get_values(opts, source_key))
    else
      attrs
    end
  end

  defp dispatch_delegate_terminal(delegation_id, args, action) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [summary: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, delegate_terminal_usage(action)),
         :ok <- start_app(),
         {:ok, delegation} <-
           update_delegate_terminal(action, delegation_id, opts[:summary] || "") do
      print_delegation(delegation, json: opts[:json] || false)
      :ok
    end
  end

  defp update_delegate_terminal("block", delegation_id, summary) do
    Workspace.block_delegation(delegation_id, summary)
  end

  defp update_delegate_terminal("fail", delegation_id, summary) do
    Workspace.fail_delegation(delegation_id, summary)
  end

  defp update_delegate_terminal("cancel", delegation_id, summary) do
    Workspace.cancel_delegation(delegation_id, summary)
  end

  defp validate_watch_patterns(success, blocker) do
    if text_present?(success) or text_present?(blocker) do
      :ok
    else
      {:error, "watch requires --success and/or --blocker pattern"}
    end
  end

  defp validate_optional_monitor_severity(nil), do: :ok

  defp validate_optional_monitor_severity(severity) do
    severities = JX.MonitorEvents.Event.severities()

    if severity in severities do
      :ok
    else
      {:error,
       "unsupported monitor severity #{inspect(severity)}; expected one of: #{Enum.join(severities, ", ")}"}
    end
  end

  defp validate_optional_wake_trigger_status(nil), do: :ok

  defp validate_optional_wake_trigger_status(status) do
    statuses = WakeTriggers.statuses()

    if status in statuses do
      :ok
    else
      {:error,
       "unsupported wake trigger status #{inspect(status)}; expected one of: #{Enum.join(statuses, ", ")}"}
    end
  end

  defp wake_schedule_attrs(opts, usage) do
    choices =
      [
        at: opts[:at],
        in: Keyword.get(opts, :in),
        every: opts[:every]
      ]
      |> Enum.filter(fn {_key, value} -> text_present?(value) end)

    case choices do
      [{:at, value}] ->
        parse_wake_at(value)

      [{:in, value}] ->
        with {:ok, seconds} <- parse_duration_seconds(value) do
          {:ok,
           %{
             schedule: "once",
             next_run_at: DateTime.add(DateTime.utc_now(), seconds, :second),
             every_seconds: nil
           }}
        end

      [{:every, value}] ->
        with {:ok, seconds} <- parse_duration_seconds(value) do
          {:ok,
           %{
             schedule: "every",
             next_run_at: DateTime.add(DateTime.utc_now(), seconds, :second),
             every_seconds: seconds
           }}
        end

      [] ->
        {:error, "usage: #{usage}"}

      _multiple ->
        {:error, "choose exactly one wake schedule: --at, --in, or --every"}
    end
  end

  defp parse_wake_at(value) do
    case DateTime.from_iso8601(value) do
      {:ok, next_run_at, _offset} ->
        {:ok, %{schedule: "once", next_run_at: next_run_at, every_seconds: nil}}

      {:error, _reason} ->
        {:error, "--at must be ISO 8601 with a timezone, for example 2026-04-28T18:00:00Z"}
    end
  end

  defp parse_duration_seconds(value) do
    value = value |> to_string() |> String.trim() |> String.downcase()

    case Regex.run(~r/^(\d+)([smhd]?)$/, value) do
      [_match, amount, unit] ->
        seconds =
          amount
          |> String.to_integer()
          |> Kernel.*(duration_multiplier(unit))

        if seconds > 0 do
          {:ok, seconds}
        else
          {:error, "duration must be positive"}
        end

      _no_match ->
        {:error, "duration must be a positive integer with optional s, m, h, or d suffix"}
    end
  end

  defp duration_multiplier("m"), do: 60
  defp duration_multiplier("h"), do: 60 * 60
  defp duration_multiplier("d"), do: 24 * 60 * 60
  defp duration_multiplier(_seconds), do: 1

  defp validate_event_ack_opts(nil, false),
    do: {:error, "jx events ack requires --to <id> or --latest"}

  defp validate_event_ack_opts(to_id, true) when not is_nil(to_id),
    do: {:error, "jx events ack accepts either --to <id> or --latest, not both"}

  defp validate_event_ack_opts(_to_id, _latest), do: :ok

  defp notification_ack_opts([], opts) do
    if opts[:all] do
      {:ok, [ref: opts[:ref], project: opts[:project]]}
    else
      {:error, "jx notifications ack requires <notification-id> or --all"}
    end
  end

  defp notification_ack_opts([notification_id], opts) do
    if opts[:all] do
      {:error, "jx notifications ack accepts either <notification-id> or --all, not both"}
    else
      {:ok, [notification_id: notification_id]}
    end
  end

  defp notification_ack_opts(_rest, _opts) do
    {:error,
     "usage: jx notifications ack <notification-id>|--all [--ref <ref>] [--project <name>] [--json]"}
  end

  defp validate_tmux_server(server) do
    if Tmux.valid_server?(server) do
      :ok
    else
      {:error,
       "invalid tmux server #{inspect(server)}; use default, #{Tmux.managed_server()}, socket:<name>, or a tmux -L name"}
    end
  end

  defp validate_non_negative(_name, value) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative(name, _value), do: {:error, "#{name} must be a non-negative integer"}

  defp validate_optional_non_negative(_name, nil), do: :ok
  defp validate_optional_non_negative(name, value), do: validate_non_negative(name, value)

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp validate_optional_positive(_name, nil), do: :ok
  defp validate_optional_positive(name, value), do: validate_positive(name, value)

  defp validate_optional_queue_kind(nil), do: :ok

  defp validate_optional_queue_kind(kind)
       when kind in ~w(workspace approval action lease agent runner assignment session),
       do: :ok

  defp validate_optional_queue_kind(kind),
    do:
      {:error,
       "unsupported queue kind #{inspect(kind)}; expected workspace, approval, action, lease, agent, runner, assignment, or session"}

  defp validate_optional_runner_session_status(nil), do: :ok

  defp validate_optional_runner_session_status(status)
       when status in ~w(created claimed running progressed completed failed stale expired ended active all),
       do: :ok

  defp validate_optional_runner_session_status(status),
    do:
      {:error,
       "unsupported session status #{inspect(status)}; expected created, claimed, running, progressed, completed, failed, stale, expired, ended, active, or all"}

  defp validate_optional_queue_risk(nil), do: :ok

  defp validate_optional_queue_risk(risk)
       when risk in ~w(blocked stale risky awaiting_operator healthy),
       do: :ok

  defp validate_optional_queue_risk(risk),
    do:
      {:error,
       "unsupported queue risk #{inspect(risk)}; expected blocked, stale, risky, awaiting_operator, or healthy"}

  defp validate_optional_freshness(nil), do: :ok
  defp validate_optional_freshness(freshness) when freshness in ~w(fresh stale unknown), do: :ok

  defp validate_optional_freshness(freshness),
    do: {:error, "unsupported freshness #{inspect(freshness)}; expected fresh, stale, or unknown"}

  defp validate_optional_queue_sort(nil), do: :ok
  defp validate_optional_queue_sort(sort) when sort in ~w(urgency freshness owner risk), do: :ok

  defp validate_optional_queue_sort(sort),
    do:
      {:error,
       "unsupported queue sort #{inspect(sort)}; expected urgency, freshness, owner, or risk"}

  defp validate_timeline_scope(scope)
       when scope in ~w(workspace approval action assignment agent runner session),
       do: :ok

  defp validate_timeline_scope(scope),
    do:
      {:error,
       "unsupported timeline scope #{inspect(scope)}; expected workspace, approval, action, assignment, agent, runner, or session"}

  defp parse_positive_integer(value, name) do
    case Integer.parse(to_string(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, "#{name} must be a positive integer"}
    end
  end

  defp task_send_opts(opts) do
    []
    |> maybe_put(:window, opts[:window])
    |> maybe_put(:pane, opts[:pane])
    |> Keyword.put(:enter, !opts[:no_enter])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp ssh_probe_targets(nil), do: SSHSessions.active_targets()
  defp ssh_probe_targets(target), do: {:ok, [target]}

  defp maybe_save_snapshot(_report, false), do: {:ok, nil}

  defp maybe_save_snapshot(report, true) do
    with {:ok, observations} <- Workspace.record_session_observations(report) do
      {:ok, length(observations)}
    end
  end

  defp run_ssh_pane_probe_all(target, timeout_ms, dry_run?) do
    with :ok <- start_app(),
         {:ok, sessions} <- SSHSessions.list(Workspace.list_hosts()) do
      if dry_run? do
        sessions
        |> PaneTransport.ssh_pane_candidates(target: target)
        |> print_pane_probe_candidates()
      else
        sessions
        |> PaneTransport.probe_ssh_sessions(target: target, timeout_ms: timeout_ms)
        |> print_pane_probe_scan()
      end

      :ok
    end
  end

  defp run_ssh_pane_probe_one(opts, server, window, pane, timeout_ms) do
    with :ok <- validate_tmux_server(server),
         {:ok, session_name} <- required_option(opts, :session, ssh_pane_probe_usage()),
         {:ok, probe} <-
           PaneTransport.probe(
             session_name: session_name,
             tmux_server: server,
             window: window,
             pane: pane,
             timeout_ms: timeout_ms
           ) do
      print_pane_probe(probe)
      :ok
    end
  end

  defp process_kinds(nil), do: {:ok, ProcessInventory.known_kinds()}

  defp process_kinds(kind) do
    if kind in ProcessInventory.known_kinds() do
      {:ok, [kind]}
    else
      {:error,
       "unsupported process kind #{inspect(kind)}; expected one of: #{Enum.join(ProcessInventory.known_kinds(), ", ")}"}
    end
  end

  defp operator_profile_attrs(opts) do
    %{}
    |> put_present(:name, opts[:name])
    |> put_present(:preferences, opts[:preferences])
    |> put_present(:working_style, opts[:style])
    |> put_present(:escalation_policy, opts[:escalation])
    |> put_present(:notes, opts[:notes])
  end

  defp put_present(attrs, _key, nil), do: attrs
  defp put_present(attrs, key, value), do: Map.put(attrs, key, value)

  defp configure_db(nil), do: :ok

  defp configure_db(path) do
    config =
      :jx
      |> Application.get_env(JX.Repo, [])
      |> Keyword.put(:database, Path.expand(path))

    Application.put_env(:jx, JX.Repo, config)
  end

  defp start_app(opts \\ []) do
    with :ok <- JX.CliRuntime.prepare() do
      configure_db(Process.get(:jx_cli_db))

      case Application.ensure_all_started(:jx) do
        {:ok, _apps} -> Migrations.migrate_started(log: Keyword.get(opts, :log, false))
        {:error, {app, reason}} -> {:error, {:application_start_failed, app, reason}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp database_path do
    :jx
    |> Application.get_env(JX.Repo, [])
    |> Keyword.fetch!(:database)
  end

  defp required_option(opts, key, usage) do
    case opts[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, "usage: #{usage}"}
    end
  end

  defp required_integer_option(opts, key, usage) do
    case opts[key] do
      value when is_integer(value) -> {:ok, value}
      _missing -> {:error, "usage: #{usage}"}
    end
  end

  defp required_message(message, _usage) when is_binary(message) and message != "" do
    {:ok, message}
  end

  defp required_message(_message, usage), do: {:error, "usage: #{usage}"}

  defp text_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp text_present?(_value), do: false

  defp plural(1), do: ""
  defp plural(_count), do: "s"

  defp print_statuses([]), do: IO.puts("no tasks")

  defp print_statuses(statuses) do
    rows =
      Enum.map(statuses, fn status ->
        task = status.task

        [
          task.task_id,
          task.project.name,
          task.host.name,
          "#{task.status}/#{status.session_status}",
          task.tmux_server,
          task.session_name,
          "#{task.window}.#{task.pane}",
          task.branch,
          task.worktree_path,
          goal_status_label(status.goal_status),
          format_time(status.last_activity)
        ]
      end)

    print_table(
      [
        "TASK",
        "PROJECT",
        "HOST",
        "STATUS",
        "SERVER",
        "SESSION",
        "PANE",
        "BRANCH",
        "WORKTREE",
        "GOAL",
        "LAST_ACTIVITY"
      ],
      rows
    )
  end

  defp goal_status_label(nil), do: "-"
  defp goal_status_label(%{"status" => status}) when status in [nil, ""], do: "-"
  defp goal_status_label(%{"status" => status}), do: status
  defp goal_status_label(_status), do: "unknown"

  defp print_directives([]), do: IO.puts("no directives")

  defp print_directives(directives) do
    rows =
      Enum.map(directives, fn directive ->
        [
          directive.directive_id,
          directive.status,
          directive.host.name,
          directive.target_type,
          directive.task_ref,
          directive.tmux_server,
          directive.session_name,
          Integer.to_string(directive.window),
          Integer.to_string(directive.pane),
          if(directive.enter, do: "yes", else: "no"),
          truncate(directive.message, 88),
          truncate(directive.error, 72),
          format_time(directive.inserted_at)
        ]
      end)

    print_table(
      [
        "DIRECTIVE",
        "STATUS",
        "HOST",
        "TARGET",
        "TASK",
        "SERVER",
        "SESSION",
        "WIN",
        "PANE",
        "ENTER",
        "MESSAGE",
        "ERROR",
        "SENT"
      ],
      rows
    )
  end

  defp print_operation_executions([], opts) do
    if opts[:json] do
      print_json(%{operations: []})
    else
      IO.puts("no operation executions")
    end
  end

  defp print_operation_executions(executions, opts) do
    if opts[:json] do
      print_json(%{operations: Enum.map(executions, &json_operation_execution/1)})
    else
      rows =
        Enum.map(executions, fn execution ->
          [
            execution.execution_id,
            execution.status,
            execution.requested,
            execution.recommendation_id,
            execution.action,
            execution.safety,
            execution.ref,
            truncate(execution.target, 48),
            truncate(operation_execution_record_result(execution), 72),
            format_time(execution.inserted_at)
          ]
        end)

      print_table(
        [
          "EXECUTION",
          "STATUS",
          "REQUESTED",
          "REC",
          "ACTION",
          "SAFETY",
          "REF",
          "TARGET",
          "RESULT",
          "AT"
        ],
        rows
      )
    end
  end

  defp print_queue(queue, opts) do
    if opts[:json] do
      print_json(queue)
    else
      IO.puts("attention queue")
      IO.puts("generated: #{format_time(queue.generated_at)}")
      IO.puts("stale_after_seconds: #{queue.stale_after_seconds}")
      print_summary_counts("queue totals", queue.totals)

      rows =
        Enum.map(queue.items, fn item ->
          [
            item.type,
            item.id,
            item.risk,
            item.reason,
            item.freshness,
            item.urgency,
            blank_to_dash(item.owner),
            blank_to_dash(item.workspace_id),
            truncate(item.summary, 72),
            item.next
          ]
        end)

      if rows == [] do
        IO.puts("")
        IO.puts("no attention items")
      else
        IO.puts("")

        print_table(
          [
            "TYPE",
            "ID",
            "RISK",
            "REASON",
            "FRESH",
            "URG",
            "OWNER",
            "WORKSPACE",
            "SUMMARY",
            "NEXT"
          ],
          rows
        )
      end
    end
  end

  defp print_queue_workspace(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("workspace queue #{report.workspace_id}")
      IO.puts("generated: #{format_time(report.generated_at)}")
      print_summary_counts("health", Map.take(report.health, [:status, :freshness, :risk]))

      print_queue_workspace_list("approvals", report.approvals, [
        :approval_id,
        :kind,
        :severity,
        :freshness,
        :owner
      ])

      print_queue_workspace_list("actions", report.actions, [
        :action_id,
        :action,
        :status,
        :outcome,
        :owner
      ])

      print_queue_workspace_list("leases", report.leases, [
        :lease_id,
        :resource_type,
        :resource_id,
        :owner,
        :status
      ])

      IO.puts("")
      IO.puts("next")
      IO.puts("  approvals: #{report.next.approvals}")
      IO.puts("  devide_status: #{report.next.devide_status}")
      IO.puts("  timeline: #{report.next.timeline}")
    end
  end

  defp print_queue_workspace_list(label, [], _fields) do
    IO.puts("")
    IO.puts("#{label}: none")
  end

  defp print_queue_workspace_list(label, items, fields) do
    IO.puts("")
    IO.puts(label)

    rows =
      Enum.map(items, fn item ->
        Enum.map(fields, fn field -> item |> Map.get(field, "") |> blank_to_dash() end)
      end)

    headers = Enum.map(fields, &(&1 |> Atom.to_string() |> String.upcase()))
    print_table(headers, rows)
  end

  defp print_operator_dashboard(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("operator dashboard")
      IO.puts("generated: #{format_time(report.generated_at)}")
      IO.puts("source: append-only operational events and existing JX read models")
      IO.puts("authority: visibility only; execution remains in DevIDE safe-action registry")
      IO.puts("")
      print_summary_counts("queue", report.queue.totals)

      print_summary_counts(
        "workspace health",
        Map.take(report.workspaces, [:total, :stale, :blocked])
      )

      print_summary_counts(
        "runner fleet",
        Map.take(report.runner_fleet, [:total, :stale, :busy, :active_sessions])
      )

      print_summary_counts(
        "runtime environments",
        Map.take(report.runtime_environments, [:total, :ready, :assigned, :stale])
      )

      print_summary_counts(
        "leases",
        %{
          total: report.leases.total,
          active: length(report.leases.active),
          stale: length(report.leases.stale),
          terminal: length(report.leases.terminal)
        }
      )

      print_summary_counts(
        "assignments",
        %{
          total: report.assignments.total,
          active: length(report.assignments.active),
          terminal: length(report.assignments.terminal),
          failed: length(report.assignments.failed)
        }
      )

      print_summary_counts(
        "reconciliation",
        Map.take(report.reconciliation, [:total, :pending, :succeeded, :failed])
      )

      print_dashboard_list("failed work", report.failures.assignments, [
        :assignment_id,
        :status,
        :workspace_id,
        :runner_id,
        :summary
      ])

      print_dashboard_events("recent events", report.recent_events)
      print_dashboard_next(report.next)
    end
  end

  defp print_operator_dashboard_workspace(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("workspace dashboard #{report.workspace_id}")
      IO.puts("generated: #{format_time(report.generated_at)}")
      print_summary_counts("health", Map.take(report.health, [:status, :freshness, :risk]))

      print_dashboard_list("approvals", report.approvals, [
        :approval_id,
        :kind,
        :severity,
        :status,
        :freshness,
        :owner
      ])

      print_dashboard_list("safe actions", report.actions, [
        :action_id,
        :action,
        :status,
        :outcome,
        :owner
      ])

      print_dashboard_list("assignments", report.assignments, [
        :assignment_id,
        :status,
        :runner_id,
        :safe_action_kind,
        :summary
      ])

      print_dashboard_list("runner sessions", report.runner_sessions, [
        :session_id,
        :status,
        :runner_id,
        :assignment_id,
        :last_summary
      ])

      print_dashboard_list("leases", report.leases, [
        :lease_id,
        :resource_type,
        :resource_id,
        :owner,
        :status
      ])

      print_dashboard_events("timeline", report.timeline.events)
      print_dashboard_next(report.next)
    end
  end

  defp print_operator_dashboard_runner(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("runner dashboard #{report.runner_id}")
      IO.puts("generated: #{format_time(report.generated_at)}")

      print_summary_counts(
        "runner",
        Map.take(report.runner, [:status, :host_name, :stale, :active_sessions])
      )

      print_dashboard_list("sessions", report.sessions, [
        :session_id,
        :status,
        :workspace_id,
        :assignment_id,
        :last_summary
      ])

      print_dashboard_list("assignments", report.assignments, [
        :assignment_id,
        :status,
        :workspace_id,
        :action_id,
        :summary
      ])

      print_dashboard_list("reports", report.reports, [
        :report_id,
        :kind,
        :status,
        :assignment_id,
        :summary
      ])

      print_dashboard_events("timeline", report.timeline.events)
      print_dashboard_next(report.next)
    end
  end

  defp print_operator_dashboard_assignment(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("assignment dashboard #{report.assignment_id}")
      IO.puts("generated: #{format_time(report.generated_at)}")

      print_summary_counts(
        "assignment",
        Map.take(report.assignment, [
          :status,
          :workspace_id,
          :action_id,
          :runner_id,
          :session_id,
          :correlation_id
        ])
      )

      print_summary_counts(
        "replay",
        Map.take(report.replay, [:status, :devide_assignment_id, :failure_class])
      )

      print_dashboard_list("assignment reports", report.reports, [
        :report_id,
        :kind,
        :status,
        :agent_id,
        :summary
      ])

      print_dashboard_list("runner reports", report.runner_reports, [
        :report_id,
        :kind,
        :status,
        :runner_id,
        :summary
      ])

      print_dashboard_list("failure chain", report.failure_chain, [
        :kind,
        :status,
        :failure_class,
        :summary
      ])

      print_dashboard_events("timeline", report.timeline.events)
      print_dashboard_next(report.next)
    end
  end

  defp print_operator_dashboard_action(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("safe-action dashboard #{report.action_id}")
      IO.puts("generated: #{format_time(report.generated_at)}")

      print_summary_counts(
        "safe action",
        Map.take(report.action, [:action_id, :safe_action, :status, :outcome, :approval_id])
      )

      if report.approval do
        print_summary_counts(
          "approval",
          Map.take(report.approval, [:approval_id, :status, :kind, :severity])
        )
      end

      print_dashboard_list("execution evidence", report.execution_events, [
        :event_id,
        :kind,
        :status,
        :summary
      ])

      print_dashboard_list("assignments", report.assignments, [
        :assignment_id,
        :status,
        :workspace_id,
        :runner_id,
        :summary
      ])

      print_dashboard_list("reconciliation", report.reconciliation.items, [
        :assignment_id,
        :status,
        :devide_assignment_id,
        :failure_class,
        :last_reconciled_at
      ])

      print_dashboard_events("timeline", report.timeline.events)
      print_dashboard_next(report.next)
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

  defp print_dashboard_events(label, []) do
    IO.puts("")
    IO.puts("#{label}: none")
  end

  defp print_dashboard_events(label, events) do
    print_dashboard_list(label, events, [
      :event_id,
      :kind,
      :severity,
      :entity_type,
      :entity_id,
      :summary
    ])
  end

  defp print_dashboard_next(next) do
    IO.puts("")
    IO.puts("next")

    next
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.each(fn {key, value} ->
      IO.puts("  #{key}: #{value}")
    end)
  end

  defp dashboard_value(%DateTime{} = value), do: format_time(value)

  defp dashboard_value(value) when is_list(value),
    do: Enum.map_join(value, ",", &dashboard_value/1)

  defp dashboard_value(value) when is_map(value), do: Jason.encode!(value)
  defp dashboard_value(value), do: value |> blank_to_dash() |> truncate(80)

  defp print_rebuilt_state(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("rebuilt operational state")
      IO.puts("events: #{report.events}")
      print_summary_counts("queue", report.queue)
    end
  end

  defp print_events_check(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("operational event check: #{report.status}")
      IO.puts("checked: #{format_time(report.checked_at)}")
      IO.puts("events: #{report.events}")
      print_summary_counts("rebuilt", report.rebuilt)

      print_summary_counts(
        "queue",
        Map.take(report.queue, [:open_approvals, :planned_actions, :active_leases])
      )

      if report.issues == [] do
        IO.puts("")
        IO.puts("issues: none")
      else
        rows =
          Enum.map(report.issues, fn issue ->
            [
              issue.severity,
              issue.problem,
              blank_to_dash(issue.id),
              "#{issue.entity_type}:#{issue.entity_id}",
              truncate(issue.summary, 72),
              truncate(issue.next, 72)
            ]
          end)

        IO.puts("")
        print_table(["SEVERITY", "PROBLEM", "ID", "ENTITY", "SUMMARY", "NEXT"], rows)
      end

      unless report.next == [] do
        IO.puts("")
        IO.puts("next")
        Enum.each(report.next, &IO.puts("  - #{&1}"))
      end
    end
  end

  defp print_runner_sessions(sessions, opts) do
    packets = Enum.map(sessions, &json_runner_session/1)

    if opts[:json] do
      print_json(%{sessions: packets})
    else
      if packets == [] do
        IO.puts("no runner sessions")
      else
        rows =
          Enum.map(packets, fn session ->
            [
              session.session_id,
              session.status,
              session.runner_id,
              session.assignment_id,
              session.workspace_id,
              session.tmux_session_name,
              truncate(session.last_summary, 64),
              session.next
            ]
          end)

        print_table(
          ["ID", "STATUS", "RUNNER", "ASSIGNMENT", "WORKSPACE", "TMUX", "SUMMARY", "NEXT"],
          rows
        )
      end
    end
  end

  defp print_runner_session(label, session, opts) do
    packet = json_runner_session(session)

    if opts[:json] do
      print_json(packet)
    else
      IO.puts("#{label} #{packet.session_id}")
      IO.puts("status: #{packet.status}")
      IO.puts("runner: #{packet.runner_id}")
      IO.puts("agent: #{packet.agent_id}")
      IO.puts("assignment: #{packet.assignment_id}")
      IO.puts("workspace: #{packet.workspace_id}")
      IO.puts("action: #{packet.action_id}")
      IO.puts("correlation_id: #{packet.correlation_id}")
      IO.puts("tmux: #{packet.tmux_server}/#{packet.tmux_session_name}")
      IO.puts("log_path: #{blank_to_dash(packet.log_path)}")
      IO.puts("heartbeat_at: #{format_time(packet.heartbeat_at)}")
      IO.puts("expires_at: #{format_time(packet.expires_at)}")
      IO.puts("summary: #{blank_to_dash(packet.last_summary)}")
      IO.puts("next: #{packet.next}")
    end
  end

  defp print_runner_session_logs(result, opts) do
    packet = %{
      session: json_runner_session(result.session),
      log_path: result.log_path,
      tmux_server: result.tmux_server,
      tmux_session_name: result.tmux_session_name,
      note: result.note
    }

    if opts[:json] do
      print_json(packet)
    else
      IO.puts("session logs #{packet.session.session_id}")
      IO.puts("log_path: #{blank_to_dash(packet.log_path)}")
      IO.puts("tmux: #{packet.tmux_server}/#{packet.tmux_session_name}")
      IO.puts(packet.note)
    end
  end

  defp print_runner_session_attach(result, opts) do
    packet = %{
      session: json_runner_session(result.session),
      command: result.command,
      note: result.note
    }

    if opts[:json] do
      print_json(packet)
    else
      IO.puts("session attach #{packet.session.session_id}")
      IO.puts("command: #{packet.command}")
      IO.puts(packet.note)
    end
  end

  defp print_runner_session_expiration(sessions, opts) do
    packets = Enum.map(sessions, &json_runner_session/1)

    if opts[:json] do
      print_json(%{expired: packets})
    else
      IO.puts("expired #{length(packets)} runner session#{plural(length(packets))}")

      Enum.each(
        packets,
        &IO.puts("  #{&1.session_id} #{&1.assignment_id} #{&1.runner_id}")
      )
    end
  end

  defp json_runner_session(%JX.DelegatedExecution.RunnerSession{} = session) do
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

  defp runner_session_next(%{status: status, session_id: id})
       when status in ["claimed", "running", "progressed", "stale"],
       do: "jx sessions show #{id}"

  defp runner_session_next(%{session_id: id}), do: "jx timeline session #{id}"

  defp print_timeline(timeline, opts) do
    if opts[:json] do
      print_json(%{
        scope: timeline.scope,
        id: timeline.id,
        events: Enum.map(timeline.events, &json_operational_event/1),
        rebuilt: timeline.rebuilt
      })
    else
      IO.puts("timeline #{timeline.scope} #{timeline.id}")

      if timeline.events == [] do
        IO.puts("events: none")
      else
        IO.puts("events")

        Enum.each(timeline.events, fn event ->
          note = timeline_note(event)

          IO.puts(
            "  - #{format_time(event.inserted_at)} #{event.kind} corr=#{event.correlation_id} entity=#{event.entity_type}:#{event.entity_id} owner=#{blank_to_dash(event.owner)} #{event.summary}#{note}"
          )
        end)
      end
    end
  end

  defp timeline_note(event) do
    payload = JX.OperationalEvents.decode_payload(event)

    cond do
      event.kind == "safe_action.execute_denied" ->
        denial = Map.get(payload, "denial", %{})

        " outcome=#{blank_to_dash(Map.get(denial, "outcome"))} reason=#{blank_to_dash(Map.get(denial, "reason"))} next=jx actions show #{event.action_id}"

      event.kind in ["lease.expired", "lease.reassigned"] ->
        " next=jx leases ls --resource #{timeline_lease_resource(payload)} --status all"

      event.kind == "approval.acknowledged" ->
        " next=jx actions history #{event.approval_id}"

      event.kind == "safe_action.executed" ->
        " next=jx actions show #{event.action_id}"

      event.entity_type not in JX.OperationalEvents.Event.entity_types() ->
        " note=unknown_entity_type"

      payload == %{} and event.payload not in [nil, "", "{}"] ->
        " note=payload_unavailable"

      true ->
        ""
    end
  end

  defp timeline_lease_resource(payload) when is_map(payload) do
    type = Map.get(payload, "resource_type", "approval")
    id = Map.get(payload, "resource_id", "")
    "#{type}:#{id}"
  end

  defp timeline_lease_resource(_payload), do: "approval:<id>"

  defp json_operational_event(event) do
    %{
      event_id: event.event_id,
      correlation_id: event.correlation_id,
      source: event.source,
      kind: event.kind,
      entity_type: event.entity_type,
      entity_id: event.entity_id,
      workspace_id: event.workspace_id,
      approval_id: event.approval_id,
      action_id: event.action_id,
      lease_id: event.lease_id,
      owner: event.owner,
      severity: event.severity,
      summary: event.summary,
      payload: JX.OperationalEvents.decode_payload(event),
      inserted_at: event.inserted_at
    }
  end

  defp print_notifications([], opts) do
    if opts[:json] do
      print_json(%{notifications: []})
    else
      IO.puts("no notifications")
    end
  end

  defp print_notifications(notifications, opts) do
    if opts[:json] do
      print_json(%{notifications: Enum.map(notifications, &json_notification/1)})
    else
      rows =
        Enum.map(notifications, fn notification ->
          [
            notification.notification_id,
            notification.status,
            notification.severity,
            notification.kind,
            notification.ref,
            notification.project,
            truncate(notification.summary, 96),
            format_time(notification.updated_at)
          ]
        end)

      print_table(["ID", "STATUS", "SEVERITY", "KIND", "REF", "PROJECT", "SUMMARY", "AT"], rows)
    end
  end

  defp print_notification_ack(%{acknowledged: _count} = result, opts) do
    if opts[:json] do
      print_json(result)
    else
      count = result.acknowledged
      IO.puts("acknowledged #{count} notification#{plural(count)}")
    end
  end

  defp print_notification_ack(notification, opts) do
    if opts[:json] do
      print_json(json_notification(notification))
    else
      IO.puts("acknowledged #{notification.notification_id}")
    end
  end

  defp print_notification_compaction(result, opts) do
    if opts[:json] do
      print_json(result)
    else
      IO.puts(
        "dismissed #{result.dismissed} duplicate notification#{plural(result.dismissed)}; kept #{result.kept} unread notification#{plural(result.kept)} across #{result.duplicate_groups} duplicate group#{plural(result.duplicate_groups)}"
      )
    end
  end

  defp print_orchestrator_heartbeats([], opts) do
    if opts[:json] do
      print_json(%{heartbeats: []})
    else
      IO.puts("no orchestrator heartbeats")
    end
  end

  defp print_orchestrator_heartbeats(heartbeats, opts) do
    if opts[:json] do
      print_json(%{heartbeats: Enum.map(heartbeats, &json_orchestrator_heartbeat/1)})
    else
      rows =
        Enum.map(heartbeats, fn heartbeat ->
          guidance = heartbeat_guidance(heartbeat)

          [
            heartbeat.daemon_key,
            heartbeat.status,
            heartbeat.consumer,
            heartbeat.mode,
            format_time(heartbeat.last_scan_at),
            format_time(heartbeat.last_decision_at),
            format_time(heartbeat.next_wake_at),
            truncate(Map.get(guidance, "top_priority", ""), 56),
            truncate(Enum.join(Map.get(guidance, "operator_needed_for", []), ","), 40),
            truncate(heartbeat.last_error, 40)
          ]
        end)

      print_table(
        [
          "KEY",
          "STATUS",
          "CONSUMER",
          "MODE",
          "SCAN",
          "DECISION",
          "NEXT",
          "TOP",
          "NEEDS",
          "ERROR"
        ],
        rows
      )
    end
  end

  defp print_orchestrator_health(health, opts) do
    if opts[:json] do
      print_json(json_orchestrator_health(health))
    else
      IO.puts("orchestrator health: #{health.status}")
      IO.puts("alerts: #{health.alerts_total}")
      IO.puts("heartbeats: #{health.heartbeats_total}")

      if health.alerts != [] do
        IO.puts("")
        print_orchestrator_health_alerts(health.alerts)
      end

      if health.heartbeats != [] do
        IO.puts("")
        print_orchestrator_heartbeats(health.heartbeats, json: false)
      end
    end
  end

  defp print_orchestrator_health_alerts(alerts) do
    rows =
      Enum.map(alerts, fn alert ->
        [
          Map.get(alert, :daemon_key, ""),
          Map.get(alert, :severity, ""),
          Map.get(alert, :reason, ""),
          Map.get(alert, :status, ""),
          format_time(Map.get(alert, :last_scan_at)),
          format_time(Map.get(alert, :next_wake_at)),
          truncate(Map.get(alert, :summary, ""), 80)
        ]
      end)

    print_table(["KEY", "SEVERITY", "REASON", "STATUS", "SCAN", "NEXT", "SUMMARY"], rows)
  end

  defp print_session_controls([], opts) do
    if opts[:json] do
      print_json(%{controls: []})
    else
      IO.puts("no session controls")
    end
  end

  defp print_session_controls(controls, opts) do
    if opts[:json] do
      print_json(%{controls: Enum.map(controls, &json_session_control/1)})
    else
      rows =
        Enum.map(controls, fn control ->
          [
            control.ref,
            control.mode,
            control.project,
            control.host,
            control.type,
            control.kind,
            control.ssh_target,
            control.tmux_server,
            control.session_name,
            format_optional_integer(control.window),
            format_optional_integer(control.pane),
            truncate(control.current_path, 64),
            truncate(control.note, 64),
            format_time(control.updated_at)
          ]
        end)

      print_table(
        [
          "REF",
          "MODE",
          "PROJECT",
          "HOST",
          "TYPE",
          "KIND",
          "SSH_TARGET",
          "SERVER",
          "SESSION",
          "WIN",
          "PANE",
          "PATH",
          "NOTE",
          "UPDATED"
        ],
        rows
      )
    end
  end

  defp print_session_watches([], opts) do
    if opts[:json] do
      print_json(%{watches: []})
    else
      IO.puts("no session watches")
    end
  end

  defp print_session_watches(watches, opts) do
    if opts[:json] do
      print_json(%{watches: Enum.map(watches, &json_session_watch/1)})
    else
      print_watches_table(watches)
    end
  end

  defp print_session_watch(watch, opts) do
    if opts[:json] do
      print_json(json_session_watch(watch))
    else
      print_watches_table([watch])
    end
  end

  defp print_watch_review(review, opts) do
    if opts[:json] do
      print_json(%{
        watch: json_session_watch(review.watch),
        previous_status: review.previous_status,
        status: review.status,
        changed: review.changed,
        summary: review.summary,
        profile: review.profile,
        observation_refresh: review.observation_refresh,
        errors: Enum.map(review.errors, &json_error/1)
      })
    else
      IO.puts("watch review #{review.watch.watch_id}")
      IO.puts("status: #{review.previous_status} -> #{review.status}")
      IO.puts("changed: #{format_bool(review.changed)}")
      IO.puts("summary: #{review.summary}")
      IO.puts("")
      print_watches_table([review.watch])

      unless review.errors == [] do
        IO.puts("")
        print_summary_errors(review.errors)
      end
    end
  end

  defp print_watches_table(watches) do
    rows =
      Enum.map(watches, fn watch ->
        [
          watch.watch_id,
          watch.status,
          watch.mode,
          watch.ref,
          truncate(watch.project, 24),
          truncate(watch.goal, 56),
          truncate(watch.success_pattern, 32),
          truncate(watch.blocker_pattern, 32),
          truncate(watch.result_summary, 72),
          format_time(watch.updated_at)
        ]
      end)

    print_table(
      [
        "WATCH",
        "STATUS",
        "MODE",
        "REF",
        "PROJECT",
        "GOAL",
        "SUCCESS",
        "BLOCKER",
        "RESULT",
        "UPDATED"
      ],
      rows
    )
  end

  defp print_remote_observations([], opts) do
    if opts[:json] do
      print_json(%{remote_sessions: []})
    else
      IO.puts("no remote session observations")
    end
  end

  defp print_remote_observations(observations, opts) do
    if opts[:json] do
      print_json(%{remote_sessions: Enum.map(observations, &json_remote_observation/1)})
    else
      rows =
        Enum.map(observations, fn observation ->
          [
            observation.ssh_target,
            observation.local_ref,
            observation.tmux_server,
            observation.session_name,
            Integer.to_string(observation.attached),
            Integer.to_string(observation.windows),
            truncate(observation.current_path, 80),
            observation.recommendation_id,
            format_time(observation.inserted_at)
          ]
        end)

      print_table(
        [
          "SSH_TARGET",
          "LOCAL_REF",
          "SERVER",
          "SESSION",
          "ATTACHED",
          "WINDOWS",
          "PATH",
          "REC",
          "OBSERVED"
        ],
        rows
      )
    end
  end

  defp print_manage_report(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      rows =
        Enum.map(report.runs, fn run ->
          [
            Integer.to_string(run.iteration),
            run.mode,
            Integer.to_string(run.observed),
            Integer.to_string(run.executed),
            Integer.to_string(run.skipped),
            Integer.to_string(run.audit.saved),
            Integer.to_string(run.attention),
            Integer.to_string(run.gated),
            Integer.to_string(run.manual)
          ]
        end)

      IO.puts("manage policy #{report.policy}")

      print_table(
        ["ITER", "MODE", "OBSERVED", "EXECUTED", "SKIPPED", "AUDIT", "ATTN", "GATED", "MANUAL"],
        rows
      )
    end
  end

  defp print_work_board(%{items: [], errors: []} = board, opts) do
    if opts[:json] do
      print_json(json_work_board(board))
    else
      if Map.get(board, :delegation_reviews, []) == [] do
        IO.puts("no work items")
      else
        print_inbox_delegation_reviews(board.delegation_reviews)
      end
    end
  end

  defp print_work_board(board, opts) do
    if opts[:json] do
      print_json(json_work_board(board))
    else
      rows =
        Enum.map(board.items, fn item ->
          [
            item.ref,
            item.control_mode,
            item.type,
            item.kind,
            item.work_state,
            item.allowed_action,
            format_bool(item.can_direct),
            work_board_git_summary(item.git),
            truncate(item.project, 24),
            truncate(item.pane, 36),
            truncate(item.current_path, 48),
            truncate(item.task, 72)
          ]
        end)

      print_table(
        [
          "REF",
          "CONTROL",
          "TYPE",
          "KIND",
          "WORK",
          "ALLOW",
          "DIRECT",
          "GIT",
          "PROJECT",
          "PANE",
          "PATH",
          "TASK"
        ],
        rows
      )

      unless Map.get(board, :delegation_reviews, []) == [] do
        IO.puts("")
        print_inbox_delegation_reviews(board.delegation_reviews)
      end

      unless board.errors == [] do
        IO.puts("")

        rows =
          Enum.map(board.errors, fn error ->
            [
              error.host,
              error.transport,
              error.subsystem,
              format_error(error.error)
            ]
          end)

        print_table(["HOST", "TRANSPORT", "SUBSYSTEM", "ERROR"], rows)
      end
    end
  end

  defp print_ci_digest(digest, opts) do
    if opts[:json] do
      print_json(digest)
    else
      IO.puts("ci digest")
      IO.puts("repo: #{digest.repo}")
      IO.puts("pr: ##{digest.pr}")
      IO.puts("overall: #{digest.overall}")
      IO.puts("")

      print_summary_counts("checks", digest.totals)

      if digest.blockers != [] do
        IO.puts("")
        IO.puts("blockers")

        rows =
          Enum.map(digest.blockers, fn blocker ->
            [
              blocker.check || "",
              blocker.type || "",
              truncate(blocker.summary || "", 72),
              truncate(blocker.evidence || "", 96)
            ]
          end)

        print_table(["CHECK", "TYPE", "SUMMARY", "EVIDENCE"], rows)
      end

      IO.puts("")

      rows =
        Enum.map(digest.checks, fn check ->
          [
            check.name || "",
            check.bucket || "",
            check.state || "",
            check.workflow || ""
          ]
        end)

      print_table(["CHECK", "BUCKET", "STATE", "WORKFLOW"], rows)
    end
  end

  defp print_ci_watches([], opts) do
    if opts[:json] do
      print_json(%{ci_watches: []})
    else
      IO.puts("no CI watches")
    end
  end

  defp print_ci_watches(watches, opts) do
    if opts[:json] do
      print_json(%{ci_watches: Enum.map(watches, &json_ci_watch/1)})
    else
      print_ci_watches_table(watches)
    end
  end

  defp print_ci_watch(watch, opts) do
    if opts[:json] do
      print_json(json_ci_watch(watch))
    else
      print_ci_watches_table([watch])
    end
  end

  defp print_ci_watch_review(review, opts) do
    if opts[:json] do
      print_json(%{
        watch: json_ci_watch(review.watch),
        previous_status: review.previous_status,
        status: review.status,
        changed: review.changed?,
        summary: review.summary,
        profile_action: maybe_json_watch_action(Map.get(review, :profile_action)),
        digest: review.digest
      })
    else
      IO.puts("CI watch review #{review.watch.watch_id}")
      IO.puts("status: #{review.previous_status} -> #{review.status}")
      IO.puts("changed: #{format_bool(review.changed?)}")
      IO.puts("summary: #{review.summary}")
      IO.puts("")
      print_ci_watches_table([review.watch])

      if review.digest do
        IO.puts("")
        print_summary_counts("checks", review.digest.totals)
      end
    end
  end

  defp print_ci_watches_table(watches) do
    rows =
      Enum.map(watches, fn watch ->
        [
          watch.watch_id,
          watch.status,
          watch.mode,
          watch.repo,
          "##{watch.pr_number}",
          watch.ref,
          truncate(watch.project, 24),
          truncate(short_sha(Map.get(watch, :head_sha)), 12),
          truncate(watch.goal, 48),
          truncate(watch.last_summary, 72),
          format_time(watch.updated_at)
        ]
      end)

    print_table(
      [
        "WATCH",
        "STATUS",
        "MODE",
        "REPO",
        "PR",
        "REF",
        "PROJECT",
        "HEAD",
        "GOAL",
        "SUMMARY",
        "UPDATED"
      ],
      rows
    )
  end

  defp print_tui_plan(plan, json: true), do: print_json(plan)

  defp print_tui_plan(plan, json: false) do
    IO.puts(Map.get(plan, :name, "jx TUI runbook"))
    IO.puts("generated: #{Map.get(plan, :generated_at, "-")}")
    IO.puts("")
    IO.puts("objective")
    IO.puts(Map.get(plan, :objective, ""))
    IO.puts("")
    IO.puts("monitor loop")

    rows =
      plan
      |> Map.get(:monitor_loop, [])
      |> Enum.map(fn step ->
        [
          step |> Map.get(:step, 0) |> Integer.to_string(),
          Map.get(step, :name, ""),
          Map.get(step, :command, ""),
          truncate(Map.get(step, :evidence, ""), 80)
        ]
      end)

    print_table(["STEP", "NAME", "COMMAND", "EVIDENCE"], rows)

    IO.puts("")
    IO.puts("watch surface")
    watch_surface = Map.get(plan, :watch_surface, %{})

    print_table(
      ["FIELD", "VALUE"],
      [
        ["command", Map.get(watch_surface, :command, "")],
        ["stop", Map.get(watch_surface, :stop, "")],
        ["safe_by_default", format_bool(Map.get(watch_surface, :safe_by_default, false))],
        ["side_effects", truncate(Map.get(watch_surface, :side_effects, ""), 100)]
      ]
    )

    print_tui_plan_list("decision gates", Map.get(plan, :decision_gates, []))
    print_tui_plan_surfaces(Map.get(plan, :primary_surfaces, []))
    print_tui_plan_list("success criteria", Map.get(plan, :success_criteria, []))
  end

  defp print_tui_plan_list(title, items) do
    IO.puts("")
    IO.puts(title)

    rows =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {item, index} -> [Integer.to_string(index), item] end)

    print_table(["#", "ITEM"], rows)
  end

  defp print_tui_plan_surfaces(surfaces) do
    IO.puts("")
    IO.puts("primary surfaces")

    rows =
      Enum.map(surfaces, fn surface ->
        [Map.get(surface, :name, ""), Map.get(surface, :command, "")]
      end)

    print_table(["SURFACE", "COMMAND"], rows)
  end

  defp print_tui_snapshot(snapshot, opts) do
    if opts[:json] do
      print_json(snapshot)
    else
      print_tui_snapshot_text(snapshot)
    end
  end

  defp print_tui_snapshot_text(snapshot) do
    filters = Map.get(snapshot, :filters, %{})
    active_filters = tui_active_filter_text(filters)

    IO.puts("jx TUI | #{Map.get(snapshot, :generated_at, "-")} | #{tui_observe_text(filters)}")

    unless active_filters == "none", do: IO.puts("filters: #{active_filters}")
    IO.puts("")

    print_tui_attention(snapshot)
    print_tui_next(Map.get(snapshot, :next, %{}))
    print_tui_queue(Map.get(snapshot, :agenda, []))
    print_tui_projects(Map.get(snapshot, :projects, []))
    print_tui_daemon(snapshot)
    print_tui_inbox(Map.get(snapshot, :monitor, %{}))
    print_tui_actions(Map.get(snapshot, :commands, []))
  end

  defp tui_active_filter_text(filters) do
    [:project, :host, :type, :ssh_target, :work_state, :control]
    |> Enum.map(fn key -> {key, Map.get(filters, key)} end)
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
    |> Enum.join(" ")
    |> case do
      "" -> "none"
      text -> text
    end
  end

  defp tui_observe_text(filters) do
    if Map.get(filters, :observe, true), do: "observing", else: "stored-state"
  end

  defp print_tui_attention(snapshot) do
    counts = Map.get(snapshot, :counts, %{})
    health = Map.get(snapshot, :health, %{})
    agenda = Map.get(snapshot, :agenda, [])
    orchestrator = Map.get(snapshot, :orchestrator, %{})
    monitor = Map.get(snapshot, :monitor, %{})
    label = tui_attention_label(counts, health, agenda, monitor)

    parts =
      [
        positive_count_phrase(tui_count(counts, :warning_notifications), "warning"),
        positive_count_phrase(tui_count(counts, :blocked_sessions), "blocked session"),
        positive_count_phrase(tui_count(counts, :running_sessions), "running session"),
        tui_monitor_alert(monitor),
        tui_daemon_summary(orchestrator),
        tui_health_summary(health, agenda)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    IO.puts("#{label} #{Enum.join(parts, " | ")}")

    headline = Map.get(snapshot, :headline, "")
    if text_present?(headline), do: IO.puts("headline: #{truncate(headline, 140)}")
  end

  defp tui_attention_label(counts, health, agenda, monitor) do
    if tui_count(health, :alerts_total) > 0 or tui_health_warning_count(agenda) > 0 or
         tui_monitor_alert(monitor) != nil or
         tui_count(counts, :warning_notifications) > 0 or
         tui_count(counts, :blocked_sessions) > 0 do
      "ATTENTION"
    else
      "OK"
    end
  end

  defp print_tui_next(next_step) do
    IO.puts("")
    IO.puts("NEXT")
    IO.puts(truncate(Map.get(next_step, :next, ""), 140))
    IO.puts(Map.get(next_step, :command, ""))

    reason = Map.get(next_step, :reason, "")
    if text_present?(reason), do: IO.puts("why: #{truncate(reason, 140)}")
  end

  defp print_tui_queue([]) do
    IO.puts("")
    IO.puts("QUEUE")
    IO.puts("no agenda items")
  end

  defp print_tui_queue(agenda) do
    IO.puts("")
    IO.puts("QUEUE")

    rows =
      agenda
      |> Enum.with_index(1)
      |> Enum.map(fn {item, index} ->
        [
          Integer.to_string(index),
          item |> Map.get(:priority, 0) |> Integer.to_string(),
          tui_agenda_severity(item),
          Map.get(item, :ref, ""),
          truncate(Map.get(item, :project, ""), 18),
          truncate(Map.get(item, :label, ""), 96)
        ]
      end)

    print_table(["#", "PRI", "SEV", "REF", "PROJECT", "ITEM"], rows)
  end

  defp print_tui_projects([]), do: :ok

  defp print_tui_projects(projects) do
    IO.puts("")
    IO.puts("PROJECTS")

    rows =
      Enum.map(projects, fn project ->
        [
          truncate(Map.get(project, :name, ""), 22),
          truncate(Map.get(project, :host, ""), 12),
          project |> Map.get(:sessions_total, 0) |> Integer.to_string(),
          tui_project_state(project),
          truncate(Map.get(project, :next_action, ""), 64)
        ]
      end)

    print_table(["PROJECT", "HOST", "SESS", "STATE", "NEXT"], rows)
  end

  defp print_tui_daemon(snapshot) do
    orchestrator = Map.get(snapshot, :orchestrator, %{})
    health = Map.get(snapshot, :health, %{})
    agenda = Map.get(snapshot, :agenda, [])

    IO.puts("")
    IO.puts("DAEMON")
    IO.puts("#{tui_daemon_summary(orchestrator)} | #{tui_health_summary(health, agenda)}")

    priority = Map.get(orchestrator, :top_priority, "")
    autonomous_next = Map.get(orchestrator, :autonomous_next, "")
    operator_needed_for = Map.get(orchestrator, :operator_needed_for, [])

    if text_present?(priority), do: IO.puts("priority: #{truncate(priority, 140)}")

    if text_present?(autonomous_next),
      do: IO.puts("autonomous: #{truncate(autonomous_next, 140)}")

    unless operator_needed_for == [] do
      IO.puts("needs: #{operator_needed_for |> Enum.join(", ") |> truncate(140)}")
    end
  end

  defp print_tui_inbox(monitor) do
    IO.puts("")
    IO.puts("INBOX")

    IO.puts(
      "#{Map.get(monitor, :consumer, "")} | unread #{tui_count(monitor, :unread_total)} | latest ##{tui_count(monitor, :latest_event_id)} | caught up #{format_bool(Map.get(monitor, :caught_up, false))}"
    )

    if Map.get(monitor, :latest_event) do
      event = Map.get(monitor, :latest_event)

      IO.puts(
        "latest: ##{Map.get(event, :id, 0)} #{Map.get(event, :kind, "")} #{Map.get(event, :severity, "")} #{Map.get(event, :ref, "")} #{truncate(Map.get(event, :summary, ""), 120)}"
      )
    end
  end

  defp print_tui_actions([]), do: :ok

  defp print_tui_actions(commands) do
    IO.puts("")
    IO.puts("ACTIONS")

    rows =
      Enum.map(commands, fn command ->
        [
          Map.get(command, :label, ""),
          Map.get(command, :command, "")
        ]
      end)

    print_table(["LABEL", "COMMAND"], rows)
  end

  defp tui_health_summary(health, agenda) do
    status = Map.get(health, :status, "unknown")
    alerts = tui_count(health, :alerts_total)
    heartbeats = tui_count(health, :heartbeats_total)
    queued_health_warnings = tui_health_warning_count(agenda)

    cond do
      alerts > 0 ->
        "health #{status}: #{count_phrase(alerts, "alert")}, #{count_phrase(heartbeats, "heartbeat")}"

      queued_health_warnings > 0 ->
        "health #{status} current, #{count_phrase(queued_health_warnings, "queued health warning")}"

      true ->
        "health #{status}, #{count_phrase(heartbeats, "heartbeat")}"
    end
  end

  defp tui_daemon_summary(orchestrator) do
    [
      Map.get(orchestrator, :status, ""),
      Map.get(orchestrator, :consumer, ""),
      Map.get(orchestrator, :mode, "")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> "daemon unknown"
      parts -> "daemon #{Enum.join(parts, " ")}"
    end
  end

  defp tui_agenda_severity(item) do
    detail = Map.get(item, :detail, "")

    case String.split(detail, " ", parts: 2) do
      [severity | _rest] when severity in ["error", "warning", "notice", "info"] ->
        severity

      _other ->
        Map.get(item, :kind, "")
    end
  end

  defp tui_health_warning_count(agenda) do
    Enum.count(agenda, fn item ->
      item
      |> Map.get(:detail, "")
      |> String.contains?("orchestrator.health")
    end)
  end

  defp tui_monitor_alert(monitor) do
    event = Map.get(monitor, :latest_event) || %{}
    severity = Map.get(event, :severity, "")

    if severity in ["critical", "error", "warning"] do
      "#{severity} latest event"
    end
  end

  defp tui_project_state(project) do
    [
      count_state(project, :blocked_total, "blocked"),
      count_state(project, :ready_total, "ready"),
      count_state(project, :awaiting_total, "awaiting"),
      count_state(project, :running_total, "running")
    ]
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> "idle"
      states -> Enum.join(states, " ")
    end
  end

  defp count_state(project, key, label) do
    case tui_count(project, key) do
      0 -> ""
      count -> "#{label}:#{count}"
    end
  end

  defp count_phrase(1, singular), do: "1 #{singular}"
  defp count_phrase(count, singular), do: "#{count} #{singular}s"
  defp positive_count_phrase(0, _singular), do: nil
  defp positive_count_phrase(count, singular), do: count_phrase(count, singular)

  defp tui_count(map, key) do
    case Map.get(map, key, 0) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _value -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp print_portfolio_summary(summary, opts) do
    if opts[:json] do
      print_json(summary)
    else
      IO.puts("portfolio summary")
      IO.puts("generated: #{format_time(summary.generated_at)}")
      IO.puts("")
      print_summary_counts("totals", summary.totals)

      if summary.projects == [] do
        IO.puts("")
        IO.puts("no portfolio projects")
      else
        IO.puts("")
        IO.puts("projects")
        print_portfolio_projects(summary.projects)
        print_portfolio_refs(summary.projects)
      end

      print_devide_portfolio(Map.get(summary, :devide))

      IO.puts("")
      print_summary_counts("observation refresh", summary.observation_refresh)

      unless summary.errors == [] do
        IO.puts("")
        print_summary_errors(summary.errors)
      end
    end
  end

  defp print_devide_portfolio(nil), do: :ok
  defp print_devide_portfolio(%{total: 0}), do: :ok

  defp print_devide_portfolio(devide) do
    IO.puts("")
    IO.puts("devide")
    IO.puts("last observed: #{format_time(Map.get(devide, :last_observed_at))}")

    print_summary_counts("devide totals", %{
      healthy: Map.get(devide, :healthy, 0),
      blocked: Map.get(devide, :blocked, 0),
      needs_review: Map.get(devide, :needs_review, 0),
      unknown: Map.get(devide, :unknown, 0)
    })

    workspaces = Map.get(devide, :workspaces, [])

    unless workspaces == [] do
      rows =
        Enum.map(workspaces, fn workspace ->
          [
            Map.get(workspace, :id, ""),
            Map.get(workspace, :status, ""),
            Map.get(workspace, :name, ""),
            Map.get(workspace, :db_isolation, ""),
            workspace |> Map.get(:attention_flags, []) |> Enum.join(",") |> truncate(72)
          ]
        end)

      print_table(["ID", "STATUS", "NAME", "DB", "FLAGS"], rows)
    end

    if Map.get(devide, :blocked, 0) + Map.get(devide, :needs_review, 0) > 0 do
      IO.puts("")
      IO.puts("devide next")
      IO.puts("  risks: jx devide risks")
      IO.puts("  approvals: jx approvals ls --source devide")
      IO.puts("  refresh snapshots: jx devide watch --state --interval-ms 5000")
    end
  end

  defp print_call_brief(brief, opts) do
    if opts[:json] do
      print_json(brief)
    else
      IO.puts("call brief")
      IO.puts("generated: #{Map.get(brief, :generated_at)}")
      IO.puts("headline: #{Map.get(brief, :headline)}")
      IO.puts("next: #{Map.get(brief, :next)}")
      IO.puts("")
      print_call_orchestrator(Map.get(brief, :orchestrator, %{}))
      print_call_agenda(Map.get(brief, :agenda, []))
      print_call_projects(Map.get(brief, :projects, []))
      print_call_brief_handoffs(Map.get(brief, :handoffs, []))
      print_call_brief_delegation_reviews(Map.get(brief, :delegation_reviews, []))
      print_call_brief_delegations(Map.get(brief, :delegations, []))
      print_call_notifications(Map.get(brief, :notifications, []))
      print_call_watches(Map.get(brief, :watches, []))
    end
  end

  defp print_call_orchestrator(orchestrator) do
    status = Map.get(orchestrator, :status, "unknown")
    consumer = Map.get(orchestrator, :consumer, "")
    mode = Map.get(orchestrator, :mode, "")

    IO.puts("orchestrator: #{Enum.join(Enum.reject([status, consumer, mode], &(&1 == "")), " ")}")

    top_priority = Map.get(orchestrator, :top_priority, "")
    autonomous_next = Map.get(orchestrator, :autonomous_next, "")
    operator_needed_for = Map.get(orchestrator, :operator_needed_for, [])

    if text_present?(top_priority), do: IO.puts("priority: #{top_priority}")
    if text_present?(autonomous_next), do: IO.puts("autonomous: #{autonomous_next}")

    unless operator_needed_for == [] do
      IO.puts("operator needed for: #{Enum.join(operator_needed_for, ", ")}")
    end
  end

  defp print_call_agenda([]) do
    IO.puts("")
    IO.puts("agenda")
    IO.puts("no agenda items")
  end

  defp print_call_agenda(agenda) do
    IO.puts("")
    IO.puts("agenda")

    rows =
      Enum.map(agenda, fn item ->
        [
          Map.get(item, :kind, ""),
          Map.get(item, :id, ""),
          Map.get(item, :ref, ""),
          Map.get(item, :project, ""),
          item |> Map.get(:priority, 0) |> Integer.to_string(),
          truncate(Map.get(item, :label, ""), 72),
          truncate(Map.get(item, :detail, ""), 40)
        ]
      end)

    print_table(["KIND", "ID", "REF", "PROJECT", "PRI", "LABEL", "DETAIL"], rows)
  end

  defp print_call_projects([]), do: :ok

  defp print_call_projects(projects) do
    IO.puts("")
    IO.puts("projects")

    rows =
      Enum.map(projects, fn project ->
        [
          Map.get(project, :name, ""),
          Map.get(project, :host, ""),
          project |> Map.get(:sessions_total, 0) |> Integer.to_string(),
          project |> Map.get(:blocked_total, 0) |> Integer.to_string(),
          project |> Map.get(:ready_total, 0) |> Integer.to_string(),
          project |> Map.get(:awaiting_total, 0) |> Integer.to_string(),
          project |> Map.get(:running_total, 0) |> Integer.to_string(),
          truncate(Map.get(project, :next_action, ""), 56),
          truncate(Map.get(project, :focus, ""), 72)
        ]
      end)

    print_table(
      ["PROJECT", "HOST", "SESS", "BLOCK", "READY", "AWAIT", "RUN", "NEXT", "FOCUS"],
      rows
    )
  end

  defp print_call_brief_handoffs([]), do: :ok

  defp print_call_brief_handoffs(handoffs) do
    IO.puts("")
    IO.puts("handoffs")

    rows =
      Enum.map(handoffs, fn handoff ->
        [
          Map.get(handoff, :id, ""),
          Map.get(handoff, :status, ""),
          Map.get(handoff, :surface, ""),
          Map.get(handoff, :ref, ""),
          Map.get(handoff, :project, ""),
          truncate(Map.get(handoff, :title, ""), 32),
          truncate(Map.get(handoff, :summary, ""), 88)
        ]
      end)

    print_table(["ID", "STATUS", "SURFACE", "REF", "PROJECT", "TITLE", "SUMMARY"], rows)
  end

  defp print_call_brief_delegation_reviews([]), do: :ok

  defp print_call_brief_delegation_reviews(reviews) do
    IO.puts("")
    IO.puts("delegation reviews")

    rows =
      Enum.map(reviews, fn review ->
        [
          Map.get(review, :id, ""),
          Map.get(review, :decision, ""),
          Map.get(review, :status, ""),
          Map.get(review, :ref, ""),
          Map.get(review, :project, ""),
          truncate(Map.get(review, :title, ""), 40),
          truncate(Map.get(review, :summary, ""), 88)
        ]
      end)

    print_table(["ID", "DECISION", "STATUS", "REF", "PROJECT", "TITLE", "SUMMARY"], rows)
  end

  defp print_call_brief_delegations([]), do: :ok

  defp print_call_brief_delegations(delegations) do
    IO.puts("")
    IO.puts("delegations")

    rows =
      Enum.map(delegations, fn delegation ->
        [
          Map.get(delegation, :id, ""),
          Map.get(delegation, :status, ""),
          delegation |> Map.get(:priority, 0) |> format_optional_integer(),
          Map.get(delegation, :agent_kind, ""),
          Map.get(delegation, :owner, ""),
          Map.get(delegation, :ref, ""),
          Map.get(delegation, :project, ""),
          truncate(Map.get(delegation, :title, ""), 40),
          truncate(Map.get(delegation, :worker_summary, ""), 72)
        ]
      end)

    print_table(
      ["ID", "STATUS", "PRI", "AGENT", "OWNER", "REF", "PROJECT", "TITLE", "SUMMARY"],
      rows
    )
  end

  defp print_call_notifications([]), do: :ok

  defp print_call_notifications(notifications) do
    IO.puts("")
    IO.puts("notifications")

    rows =
      Enum.map(notifications, fn notification ->
        [
          Map.get(notification, :id, ""),
          Map.get(notification, :severity, ""),
          Map.get(notification, :kind, ""),
          Map.get(notification, :ref, ""),
          Map.get(notification, :project, ""),
          truncate(Map.get(notification, :summary, ""), 88)
        ]
      end)

    print_table(["ID", "SEVERITY", "KIND", "REF", "PROJECT", "SUMMARY"], rows)
  end

  defp print_call_watches([]), do: :ok

  defp print_call_watches(watches) do
    IO.puts("")
    IO.puts("ci watches")

    rows =
      Enum.map(watches, fn watch ->
        [
          Map.get(watch, :id, ""),
          Map.get(watch, :status, ""),
          Map.get(watch, :mode, ""),
          Map.get(watch, :repo, ""),
          watch |> Map.get(:pr_number) |> format_optional_integer(),
          Map.get(watch, :ref, ""),
          Map.get(watch, :project, ""),
          truncate(Map.get(watch, :summary, ""), 88)
        ]
      end)

    print_table(["ID", "STATUS", "MODE", "REPO", "PR", "REF", "PROJECT", "SUMMARY"], rows)
  end

  defp print_call_handoffs([], opts) do
    if opts[:json] do
      print_json(%{handoffs: []})
    else
      IO.puts("no call handoffs")
    end
  end

  defp print_call_handoffs(handoffs, opts) do
    if opts[:json] do
      print_json(%{handoffs: Enum.map(handoffs, &json_call_handoff/1)})
    else
      rows =
        Enum.map(handoffs, fn handoff ->
          [
            handoff.handoff_id,
            handoff.status,
            handoff.surface,
            handoff.ref,
            handoff.project,
            truncate(handoff.title, 32),
            truncate(handoff.summary, 88),
            format_time(handoff.updated_at)
          ]
        end)

      print_table(
        ["ID", "STATUS", "SURFACE", "REF", "PROJECT", "TITLE", "SUMMARY", "UPDATED"],
        rows
      )
    end
  end

  defp print_call_handoff(handoff, opts) do
    if opts[:json] do
      print_json(json_call_handoff(handoff))
    else
      print_call_handoffs([handoff], json: false)
    end
  end

  defp print_call_handoff_apply(%{handoff: handoff, action: action, action_record: record}, opts) do
    if opts[:json] do
      print_json(%{
        handoff: json_call_handoff(handoff),
        action: action,
        action_record: json_orchestration_action(record)
      })
    else
      IO.puts("call handoff applied")
      print_call_handoffs([handoff], json: false)
      IO.puts("")
      IO.puts("action: #{action.action}")
      IO.puts("status: #{action.status}")
      IO.puts("ref: #{action.ref}")
      IO.puts("summary: #{action.result_summary}")
    end
  end

  defp print_call_handoff_apply(handoff, opts) do
    print_call_handoff(handoff, opts)
  end

  defp print_meet_plugin(nil, opts) do
    if opts[:json] do
      print_json(%{plugin: nil})
    else
      IO.puts("google_meet plugin is not bundled")
    end
  end

  defp print_meet_plugin(plugin, opts) do
    if opts[:json] do
      print_json(meet_json(plugin))
    else
      IO.puts("meet plugin")
      IO.puts("id: #{plugin.id}")
      IO.puts("name: #{plugin.name}")
      IO.puts("surface: #{plugin.surface}")
      IO.puts("auth: #{get_in(plugin, [:auth, :kind])}")
      IO.puts("browser: #{get_in(plugin, [:realtime, :browser])}")
      IO.puts("audio bridge: #{get_in(plugin, [:realtime, :audio_bridge])}")
    end
  end

  defp print_meet_auth_profile(profile, opts) do
    print_meet_auth_profiles([profile], opts)
  end

  defp print_meet_auth_profiles([], opts) do
    if opts[:json], do: print_json(%{profiles: []}), else: IO.puts("no Meet auth profiles")
  end

  defp print_meet_auth_profiles(profiles, opts) do
    if opts[:json] do
      print_json(%{profiles: meet_json(profiles)})
    else
      rows =
        Enum.map(profiles, fn profile ->
          [
            profile.name,
            profile.status,
            profile.email,
            profile.redirect_uri,
            format_bool(get_in(profile, [:token, :has_refresh_token]) || false),
            profile.last_error || ""
          ]
        end)

      print_table(["PROFILE", "STATUS", "EMAIL", "REDIRECT", "REFRESH", "ERROR"], rows)
    end
  end

  defp print_meet_auth_url(packet, opts) do
    if opts[:json] do
      print_json(meet_json(packet))
    else
      IO.puts("meet auth url")
      IO.puts("profile: #{get_in(packet, [:profile, :name])}")
      IO.puts("state: #{packet.state}")
      IO.puts(packet.auth_url)
    end
  end

  defp print_meet_session(session, opts) do
    session
    |> JX.GoogleMeet.session_summary()
    |> print_meet_session_packet(opts)
  end

  defp print_meet_session_packet(packet, opts) do
    print_meet_sessions([packet], opts)
  end

  defp print_meet_sessions([], opts) do
    if opts[:json], do: print_json(%{sessions: []}), else: IO.puts("no Meet sessions")
  end

  defp print_meet_sessions(sessions, opts) do
    packets =
      Enum.map(sessions, fn
        %JX.GoogleMeet.Session{} = session -> JX.GoogleMeet.session_summary(session)
        packet -> packet
      end)

    if opts[:json] do
      print_json(%{sessions: meet_json(packets)})
    else
      rows =
        Enum.map(packets, fn session ->
          [
            session.session_id,
            session.status,
            session.meeting_code,
            session.project,
            session.ref,
            session.auth_profile,
            session.twilio_mode,
            session.handoff_id,
            truncate(session.title || "", 40)
          ]
        end)

      print_table(
        ["SESSION", "STATUS", "MEET", "PROJECT", "REF", "AUTH", "TWILIO", "HANDOFF", "TITLE"],
        rows
      )
    end
  end

  defp print_meet_plan(plan, opts) do
    if opts[:json] do
      print_json(meet_json(plan))
    else
      session = plan.session
      IO.puts("meet session plan")
      IO.puts("session: #{session.session_id}")
      IO.puts("meeting: #{session.meeting_uri}")
      IO.puts("chrome: #{get_in(plan, [:chrome, :primary, :node])}")
      IO.puts("launch: #{get_in(plan, [:chrome, :primary, :launch_command])}")

      if text_present?(get_in(plan, [:chrome, :paired, :node]) || "") do
        IO.puts("paired chrome: #{get_in(plan, [:chrome, :paired, :node])}")
      end

      if text_present?(get_in(plan, [:twilio, :stream_url]) || "") do
        IO.puts(
          "twilio: #{get_in(plan, [:twilio, :mode])} #{get_in(plan, [:twilio, :stream_url])}"
        )
      end

      IO.puts("export: #{get_in(plan, [:exports, :command])}")
    end
  end

  defp print_meet_join(result, opts) do
    if opts[:json] do
      print_json(meet_json(result))
    else
      session = result.session
      runner = result.runner

      IO.puts("meet join")
      IO.puts("session: #{session.session_id}")
      IO.puts("status: #{session.status}")
      IO.puts("runner: #{runner.runner}")
      IO.puts("meeting: #{session.meeting_uri}")

      if text_present?(runner.debug_url || "") do
        IO.puts("browser: #{runner.debug_url}")
      end

      target_id = get_in(runner, [:target, "id"]) || get_in(runner, [:target, :id])

      if text_present?(target_id || "") do
        IO.puts("target: #{target_id}")
      end
    end
  end

  defp print_meet_realtime_plan(plan, opts) do
    if opts[:json] do
      print_json(meet_json(plan))
    else
      IO.puts("meet realtime plan")
      IO.puts("session: #{plan.session.session_id}")
      IO.puts("status: #{plan.status}")
      IO.puts("provider: #{plan.provider}")
      IO.puts("audio bridge: #{plan.audio_bridge}")
      IO.puts("ingress: #{plan.ingress.kind} #{format_ready(plan.ingress.ready)}")
      IO.puts("egress: #{plan.egress.kind} #{format_ready(plan.egress.ready)}")
      IO.puts("consult: #{plan.consult.tool}")

      Enum.each(plan.constraints, fn constraint ->
        IO.puts("constraint: #{constraint}")
      end)
    end
  end

  defp print_meet_realtime_start(result, opts) do
    if opts[:json] do
      print_json(meet_json(result))
    else
      IO.puts("meet realtime")
      IO.puts("session: #{result.session.session_id}")
      IO.puts("status: #{result.voice_loop["status"]}")
      IO.puts("provider: #{result.voice_loop["provider"]}")
      IO.puts("audio bridge: #{result.voice_loop["audio_bridge"]}")
    end
  end

  defp print_meet_realtime_consult(result, opts) do
    if opts[:json] do
      print_json(meet_json(result))
    else
      IO.puts("meet realtime consult")
      IO.puts("session: #{result.session.session_id}")
      IO.puts("handoff: #{result.handoff.handoff_id}")
      IO.puts("summary: #{result.handoff.summary}")
      IO.puts("response: #{result.response.spoken_summary}")
    end
  end

  defp print_meet_realtime_watch(result, opts) do
    if opts[:json] do
      print_json(meet_json(result))
    else
      IO.puts("meet realtime watch")
      IO.puts("session: #{result.session.session_id}")
      IO.puts("status: #{result.status}")
      IO.puts("iterations: #{result.iterations}")
      IO.puts("consulted: #{result.consulted}")

      result.events
      |> Enum.each(fn event ->
        line =
          [
            Map.get(event, :status),
            Map.get(event, :source) || Map.get(event, "last_input_source"),
            Map.get(event, :reason) || Map.get(event, "reason"),
            Map.get(event, :transcript_excerpt),
            Map.get(event, "transcript_excerpt"),
            get_in(event, [:handoff, :handoff_id])
          ]
          |> Enum.reject(&(is_nil(&1) or &1 == ""))
          |> Enum.join(" ")

        IO.puts("event: #{line}")
      end)
    end
  end

  defp print_meet_recovery(recovery, opts) do
    if opts[:json] do
      print_json(meet_json(recovery))
    else
      IO.puts("meet recovery")
      IO.puts("candidates: #{length(recovery.candidates)}")
      IO.puts("created: #{length(recovery.created)}")

      recovery.created
      |> Enum.each(fn session ->
        IO.puts("#{session.session_id}\t#{session.meeting_code}\t#{session.meeting_uri}")
      end)
    end
  end

  defp print_meet_export(export, opts) do
    if opts[:json] do
      print_json(meet_json(export))
    else
      IO.puts("meet export")
      IO.puts("session: #{export.session.session_id}")
      IO.puts("dir: #{export.dir}")

      Enum.each(export.files, fn file ->
        IO.puts("file: #{file}")
      end)
    end
  end

  defp print_delegations([], opts) do
    if opts[:json] do
      print_json(%{delegations: []})
    else
      IO.puts("no delegations")
    end
  end

  defp print_delegations(delegations, opts) do
    if opts[:json] do
      print_json(%{delegations: Enum.map(delegations, &json_delegation/1)})
    else
      rows =
        Enum.map(delegations, fn delegation ->
          [
            delegation.delegation_id,
            delegation.status,
            delegation_lint_text(delegation),
            delegation_review_text(delegation),
            delegation.integration_status,
            Integer.to_string(delegation.priority),
            delegation.agent_kind,
            truncate(delegation.owner, 18),
            delegation.ref,
            truncate(delegation.project, 24),
            truncate(delegation.title, 40),
            truncate(delegation.worker_summary, 72),
            format_time(delegation.updated_at)
          ]
        end)

      print_table(
        [
          "ID",
          "STATUS",
          "LINT",
          "REVIEW",
          "INTEGRATION",
          "PRI",
          "AGENT",
          "OWNER",
          "REF",
          "PROJECT",
          "TITLE",
          "SUMMARY",
          "UPDATED"
        ],
        rows
      )
    end
  end

  defp print_delegation(delegation, opts) do
    if opts[:json] do
      print_json(json_delegation(delegation))
    else
      print_delegations([delegation], json: false)
    end
  end

  defp print_delegation_preflight(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("status: #{report.status}")

      unless report.warnings == [] do
        IO.puts("warnings:")
        Enum.each(report.warnings, &IO.puts("- #{&1}"))
      end

      unless report.conflicts == [] do
        IO.puts("conflicts:")

        Enum.each(report.conflicts, fn conflict ->
          IO.puts(
            "- #{conflict.path} overlaps #{conflict.conflicting_path} in #{conflict.delegation_id}"
          )
        end)
      end
    end
  end

  defp print_delegation_review(review, opts) do
    if opts[:json] do
      print_json(review)
    else
      IO.puts("decision: #{review.decision}")
      IO.puts("summary: #{review.summary}")
      IO.puts("evidence: #{review.evidence.passed} passed, #{review.evidence.failed} failed")

      unless review.warnings == [] do
        IO.puts("warnings:")
        Enum.each(review.warnings, &IO.puts("- #{&1}"))
      end

      unless review.ownership.outside_write_paths == [] do
        IO.puts("outside write ownership:")
        Enum.each(review.ownership.outside_write_paths, &IO.puts("- #{&1}"))
      end

      unless review.residual_risks == [] do
        IO.puts("residual risks:")
        Enum.each(review.residual_risks, &IO.puts("- #{&1}"))
      end
    end
  end

  defp print_delegation_reviews([], opts) do
    if opts[:json] do
      print_json(%{reviews: []})
    else
      IO.puts("no delegation reviews")
    end
  end

  defp print_delegation_reviews(reviews, opts) do
    if opts[:json] do
      print_json(%{reviews: reviews})
    else
      rows =
        Enum.map(reviews, fn review ->
          [
            review.delegation_id,
            review.decision,
            get_in(review, [:foreground, :status]) || "",
            review.ref,
            truncate(review.project, 24),
            truncate(review.title, 36),
            truncate(review.summary, 72)
          ]
        end)

      print_table(["ID", "DECISION", "INTEGRATION", "REF", "PROJECT", "TITLE", "SUMMARY"], rows)
    end
  end

  defp print_delegation_timing(timing, opts) do
    if opts[:json] do
      print_json(timing)
    else
      IO.puts("delegation timing")
      IO.puts("generated: #{format_time(timing.generated_at)}")

      print_delegation_timing_stats("global", timing.global)

      IO.puts(
        "assignment: start=#{timing.assignment.recommended_new_starts} target=#{timing.assignment.target_parallel} reason=#{timing.assignment.reason}"
      )

      unless timing.active.items == [] do
        IO.puts("")
        IO.puts("active")

        rows =
          Enum.map(timing.active.items, fn item ->
            [
              item.delegation_id,
              item.status,
              format_bool(item.long_running),
              seconds_text(get_in(item, [:timing, :runtime_seconds])),
              seconds_text(get_in(item, [:timing, :total_seconds])),
              seconds_text(item.estimate_seconds),
              item.ref,
              truncate(item.project, 24),
              truncate(item.title, 48)
            ]
          end)

        print_table(
          ["ID", "STATUS", "LONG", "RUNTIME", "TOTAL", "EST", "REF", "PROJECT", "TITLE"],
          rows
        )
      end

      unless timing.pending_reviews.items == [] do
        IO.puts("")
        IO.puts("pending reviews")

        rows =
          Enum.map(timing.pending_reviews.items, fn item ->
            [
              item.delegation_id,
              item.decision,
              format_bool(item.stale),
              seconds_text(item.review_wait_seconds),
              item.ref,
              truncate(item.project, 24),
              truncate(item.summary, 72)
            ]
          end)

        print_table(["ID", "DECISION", "STALE", "WAIT", "REF", "PROJECT", "SUMMARY"], rows)
      end
    end
  end

  defp print_delegation_timing_stats(label, stats) do
    IO.puts(
      "#{label}: samples=#{stats.samples} avg=#{seconds_text(stats.average_runtime_seconds)} median=#{seconds_text(stats.median_runtime_seconds)} p90=#{seconds_text(stats.p90_runtime_seconds)}"
    )
  end

  defp delegation_lint_text(delegation) do
    case decode_json_text(delegation.lint_warnings) do
      [] -> "ok"
      warnings when is_list(warnings) -> "#{length(warnings)} warn"
      _other -> "warn"
    end
  end

  defp delegation_review_text(%{status: status}) when status != "completed", do: "-"

  defp delegation_review_text(delegation) do
    delegation
    |> JX.Delegations.delegation_summary()
    |> get_in([:review, :decision])
  end

  defp print_policy_overview(policy, opts) do
    if opts[:json] do
      print_json(policy)
    else
      IO.puts("policy overview")
      IO.puts("commit/push/pr: #{policy.defaults.commit_push_pr}")
      IO.puts("hold for: #{policy.defaults.hold_for}")
      IO.puts("")
      IO.puts("safety tiers")
      Enum.each(policy.safety_tiers, &print_policy_tier/1)
      IO.puts("")
      IO.puts("release rules")
      Enum.each(policy.release_rules, &print_policy_rule/1)
    end
  end

  defp print_policy_tiers(tiers, opts) do
    if opts[:json] do
      print_json(%{tiers: tiers})
    else
      IO.puts("policy safety tiers")
      Enum.each(tiers, &print_policy_tier/1)
    end
  end

  defp print_policy_tier(tier) do
    IO.puts(
      "#{tier.id}: #{tier.title}; autonomy=#{tier.autonomy}; confirmation=#{tier.confirmation}"
    )

    IO.puts("  boundary: #{tier.boundary}")

    unless tier.examples == [] do
      IO.puts("  examples: #{Enum.join(tier.examples, ", ")}")
    end

    unless tier.blocked_by == [] do
      IO.puts("  blocked by: #{Enum.join(tier.blocked_by, ", ")}")
    end
  end

  defp print_policy_rule(rule) do
    IO.puts("#{rule.action}: #{rule.decision}; confirmation=#{rule.confirmation}; #{rule.reason}")
  end

  defp print_portfolio_projects(projects) do
    rows =
      Enum.map(projects, fn project ->
        [
          project.name,
          project.host,
          if(project.registered, do: "yes", else: "no"),
          truncate(project.repo_path, 44),
          Integer.to_string(project.sessions_total),
          Integer.to_string(project.blocked_total),
          Integer.to_string(project.ready_total),
          Integer.to_string(project.awaiting_total),
          Integer.to_string(project.running_total),
          Enum.join(project.prs, ","),
          truncate(Enum.join(project.branches, ","), 36),
          truncate(project.next_action, 52),
          truncate(project.focus, 88)
        ]
      end)

    print_table(
      [
        "PROJECT",
        "HOST",
        "REG",
        "REPO",
        "SESS",
        "BLOCK",
        "READY",
        "AWAIT",
        "RUN",
        "PRS",
        "BRANCHES",
        "NEXT",
        "FOCUS"
      ],
      rows
    )
  end

  defp print_portfolio_refs(projects) do
    rows =
      projects
      |> Enum.flat_map(fn project ->
        project.refs
        |> Enum.filter(&portfolio_ref_actionable?/1)
        |> Enum.map(fn ref ->
          [
            ref.ref,
            project.name,
            ref.state,
            ref.prompt_status,
            ref.work_state,
            if(ref.can_direct, do: "yes", else: "no"),
            truncate(ref.next_step, 40),
            truncate(ref.focus, 88)
          ]
        end)
      end)

    unless rows == [] do
      IO.puts("")
      IO.puts("actionable refs")
      print_table(["REF", "PROJECT", "STATE", "PROMPT", "WORK", "DIRECT", "NEXT", "FOCUS"], rows)
    end
  end

  defp portfolio_ref_actionable?(ref) do
    ref.state in ["blocked", "ready-to-send", "awaiting-observation", "needs-attention"] or
      ref.prompt_status in ["ready", "draft", "sent", "blocked"]
  end

  defp print_processes([]), do: IO.puts("no processes")

  defp print_processes(processes) do
    rows =
      Enum.map(processes, fn process ->
        [
          process.kind,
          Integer.to_string(process.pid),
          Integer.to_string(process.ppid),
          process.stat,
          process.tty,
          process.command
        ]
      end)

    print_table(["KIND", "PID", "PPID", "STAT", "TTY", "COMMAND"], rows)
  end

  defp print_ssh_sessions([]), do: IO.puts("no ssh sessions")

  defp print_ssh_sessions(sessions) do
    rows =
      Enum.map(sessions, fn session ->
        [
          session.role,
          Integer.to_string(session.pid),
          session.stat,
          session.tty,
          session.target,
          session.registered_host,
          session.server,
          session.session,
          format_optional_integer(session.window),
          format_optional_integer(session.pane),
          truncate(session.current_path, 72),
          truncate(session.title, 48),
          truncate(session.command, 96)
        ]
      end)

    print_table(
      [
        "ROLE",
        "PID",
        "STAT",
        "TTY",
        "TARGET",
        "HOST",
        "SERVER",
        "SESSION",
        "WIN",
        "PANE",
        "PATH",
        "TITLE",
        "COMMAND"
      ],
      rows
    )
  end

  defp print_ssh_probes([]), do: IO.puts("no ssh targets")

  defp print_ssh_probes(probes) do
    rows =
      Enum.map(probes, fn probe ->
        [
          probe.target,
          probe.ssh,
          probe.tmux,
          Integer.to_string(probe.sessions),
          truncate(Map.get(probe, :detail, ""), 120)
        ]
      end)

    print_table(["TARGET", "SSH", "TMUX", "SESSIONS", "DETAIL"], rows)
  end

  defp print_pane_probe(probe) do
    print_table(
      ["PANE", "TMUX", "SESSIONS", "DETAIL"],
      [
        [
          probe.target,
          probe.tmux,
          Integer.to_string(probe.sessions),
          truncate(pane_probe_detail(probe), 120)
        ]
      ]
    )
  end

  defp print_pane_probe_scan([]), do: IO.puts("no ssh panes")

  defp print_pane_probe_scan(probes) do
    rows =
      Enum.map(probes, fn probe ->
        [
          probe.ssh_target,
          probe.registered_host,
          Integer.to_string(probe.pid),
          probe.target,
          probe.status,
          probe.tmux,
          Integer.to_string(probe.sessions),
          truncate(pane_probe_detail(probe), 120)
        ]
      end)

    print_table(
      ["SSH_TARGET", "HOST", "PID", "PANE", "STATUS", "TMUX", "SESSIONS", "DETAIL"],
      rows
    )
  end

  defp pane_probe_detail(%{error: reason}), do: format_error(reason)

  defp pane_probe_detail(%{remote_sessions: sessions}) when sessions != [] do
    sessions
    |> Enum.map(&remote_session_summary/1)
    |> Enum.join("; ")
  end

  defp pane_probe_detail(probe), do: Map.get(probe, :detail, "")

  defp remote_session_summary(session) do
    path = Map.get(session, :current_path, "")
    windows = Map.get(session, :windows, 0)
    attached = Map.get(session, :attached, 0)

    "#{session.server}/#{session.session} windows=#{windows} attached=#{attached} path=#{path}"
  end

  defp print_pane_probe_candidates([]), do: IO.puts("no ssh panes")

  defp print_pane_probe_candidates(candidates) do
    rows =
      Enum.map(candidates, fn candidate ->
        [
          candidate.target,
          candidate.registered_host,
          Integer.to_string(candidate.pid),
          "#{candidate.server}/#{candidate.session}:#{candidate.window}.#{candidate.pane}",
          truncate(candidate.current_path, 88),
          truncate(candidate.title, 56)
        ]
      end)

    print_table(["SSH_TARGET", "HOST", "PID", "PANE", "PATH", "TITLE"], rows)
  end

  defp print_discovery_report(%{sessions: [], errors: []}), do: IO.puts("no active sessions")

  defp print_discovery_report(%{sessions: sessions, errors: errors}) do
    unless sessions == [] do
      rows =
        Enum.map(sessions, fn session ->
          [
            session.host,
            session.transport,
            session.server,
            session.session,
            session.state,
            session.task_id || "",
            session.project || "",
            session.agent_name || "",
            session.worktree_path || "",
            format_time(session.created_at),
            Integer.to_string(session.attached),
            Integer.to_string(session.windows)
          ]
        end)

      print_table(
        [
          "HOST",
          "TRANSPORT",
          "SERVER",
          "SESSION",
          "STATE",
          "TASK",
          "PROJECT",
          "AGENT",
          "PATH",
          "CREATED",
          "ATTACHED",
          "WINDOWS"
        ],
        rows
      )
    end

    unless errors == [] do
      if sessions != [], do: IO.puts("")

      rows =
        Enum.map(errors, fn error ->
          [
            error.host,
            error.transport,
            format_error(error.error)
          ]
        end)

      print_table(["HOST", "TRANSPORT", "ERROR"], rows)
    end
  end

  defp print_activity_report(%{activity: [], errors: []}), do: IO.puts("no activity")

  defp print_activity_report(%{activity: activity, errors: errors}) do
    unless activity == [] do
      rows =
        Enum.map(activity, fn entry ->
          [
            entry.host,
            entry.transport,
            entry.server,
            entry.session,
            format_optional_integer(entry.window),
            format_optional_integer(entry.pane),
            entry.tty,
            format_active(entry.active),
            entry.kind,
            format_optional_integer(entry.process_pid),
            entry.process_stat,
            truncate(activity_command(entry), 96),
            truncate(entry.current_path, 88),
            truncate(entry.title, 56)
          ]
        end)

      print_table(
        [
          "HOST",
          "TRANSPORT",
          "SERVER",
          "SESSION",
          "WIN",
          "PANE",
          "TTY",
          "ACTIVE",
          "KIND",
          "PID",
          "STAT",
          "COMMAND",
          "PATH",
          "TITLE"
        ],
        rows
      )
    end

    unless errors == [] do
      if activity != [], do: IO.puts("")

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
  end

  defp print_sessions_report(report, opts)

  defp print_sessions_report(%{sessions: [], errors: []}, opts) do
    if opts[:json] do
      print_json(%{sessions: [], errors: []})
    else
      IO.puts("no sessions")
    end
  end

  defp print_sessions_report(%{sessions: sessions, errors: errors}, opts) do
    if opts[:json] do
      print_json(%{
        sessions: sessions,
        errors: Enum.map(errors, &json_error/1)
      })
    else
      print_sessions_table(sessions, errors)
    end
  end

  defp print_sessions_table(sessions, errors) do
    unless sessions == [] do
      rows =
        Enum.map(sessions, fn session ->
          [
            session.ref,
            session.host,
            session.type,
            session.state,
            Map.get(session, :control_mode, "uncontrolled"),
            session.server,
            session.session,
            format_optional_integer(session.window),
            format_optional_integer(session.pane),
            session.kind,
            session.agent_name,
            session.task_id,
            session.ssh_target,
            format_optional_integer(session.pid),
            format_active(session.active),
            session.actions,
            truncate(session.current_path, 72),
            truncate(session.title, 48)
          ]
        end)

      print_table(
        [
          "REF",
          "HOST",
          "TYPE",
          "STATE",
          "CONTROL",
          "SERVER",
          "SESSION",
          "WIN",
          "PANE",
          "KIND",
          "AGENT",
          "TASK",
          "SSH_TARGET",
          "PID",
          "ACTIVE",
          "ACTIONS",
          "PATH",
          "TITLE"
        ],
        rows
      )
    end

    unless errors == [] do
      if sessions != [], do: IO.puts("")

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
  end

  defp print_sessions_snapshot(report, opts)

  defp print_sessions_snapshot(%{sessions: [], errors: []}, opts) do
    if opts[:json] do
      %{sessions: [], errors: []}
      |> maybe_put_saved(opts[:saved])
      |> print_json()
    else
      IO.puts("no sessions")
      print_saved_count(opts[:saved])
    end
  end

  defp print_sessions_snapshot(%{sessions: sessions, errors: errors}, opts) do
    if opts[:json] do
      %{sessions: sessions, errors: Enum.map(errors, &json_error/1)}
      |> maybe_compact_snapshot(opts[:compact])
      |> maybe_put_saved(opts[:saved])
      |> print_json()
    else
      print_sessions_snapshot_table(sessions, errors)
      print_saved_count(opts[:saved])
    end
  end

  defp print_sessions_summary(summary, opts) do
    if opts[:json] do
      print_json(json_sessions_summary(summary))
    else
      IO.puts("generated #{format_time(summary.generated_at)}")
      IO.puts("")
      print_summary_counts("registry", summary.registry)
      print_registry_warnings(summary.registry)
      IO.puts("")
      print_summary_counts("current", summary.current)
      IO.puts("")
      print_summary_counts("observations", summary.observations)
      IO.puts("")
      print_summary_counts("observation refresh", summary.observation_refresh)
      IO.puts("")
      print_summary_counts("reconciliation", summary.reconciliation)
      print_reconciliation_refs(summary.reconciliation)
      IO.puts("")
      print_summary_counts("remote", summary.remote)
      IO.puts("")
      print_workflow_summary(summary.workflow)

      unless summary.attention == [] do
        IO.puts("")
        IO.puts("attention")
        print_session_changes(summary.attention, json: false)
      end

      unless summary.stale == [] do
        IO.puts("")
        IO.puts("stale")
        print_stale_sessions(summary.stale, json: false)
      end

      unless summary.errors == [] do
        IO.puts("")
        print_summary_errors(summary.errors)
      end
    end
  end

  defp print_operation(operation, opts) do
    if opts[:json] do
      print_json(json_operation(operation))
    else
      IO.puts("generated #{format_time(operation.generated_at)}")
      IO.puts("mode #{operation.mode}")
      IO.puts("")
      print_summary_counts("current", operation.state.current)
      IO.puts("")
      print_summary_counts("observations", operation.state.observations)
      IO.puts("")

      print_workflow_summary(
        Map.put(operation.state.workflow, :recommendations, operation.recommendations)
      )

      IO.puts("")
      print_operation_actions("safe actions", operation.safe_actions)
      IO.puts("")
      print_operation_actions("gated actions", operation.gated_actions)
      IO.puts("")
      print_operation_actions("manual actions", operation.manual_actions)
      IO.puts("")
      print_operation_execution(operation.execution)

      unless operation.errors == [] do
        IO.puts("")
        print_summary_errors(operation.errors)
      end
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

  defp print_registry_warnings(%{warnings: []}), do: :ok

  defp print_registry_warnings(%{warnings: warnings}) do
    IO.puts("warnings: #{Enum.join(warnings, "; ")}")
  end

  defp summary_value(value) when is_integer(value), do: Integer.to_string(value)
  defp summary_value(value) when is_boolean(value), do: format_bool(value)
  defp summary_value(value) when is_binary(value), do: value
  defp summary_value(%_struct{} = value), do: to_string(value)
  defp summary_value(nil), do: ""
  defp summary_value(value), do: inspect(value)

  defp print_operation_actions(title, []), do: IO.puts("#{title}: none")

  defp print_operation_actions(title, actions) do
    IO.puts(title)

    rows =
      Enum.map(actions, fn action ->
        [
          action.id,
          action.safety,
          action.priority,
          action.kind,
          action.action,
          action.ref,
          truncate(action.target, 64),
          truncate(action.reason, 96)
        ]
      end)

    print_table(["ID", "SAFETY", "PRIORITY", "KIND", "ACTION", "REF", "TARGET", "REASON"], rows)
  end

  defp print_operation_execution(%{mode: "dry-run"}), do: IO.puts("execution: dry-run")

  defp print_operation_execution(execution) do
    rows =
      (execution.executed ++ execution.skipped)
      |> Enum.map(fn result ->
        [
          result.status,
          result.id,
          result.action || "",
          result.safety || "",
          Map.get(result, :ref, ""),
          truncate(Map.get(result, :target, ""), 64),
          truncate(operation_execution_result(result), 96)
        ]
      end)

    IO.puts("execution #{execution.requested}")

    if rows == [] do
      IO.puts("no matching actions")
    else
      print_table(["STATUS", "ID", "ACTION", "SAFETY", "REF", "TARGET", "RESULT"], rows)
    end
  end

  defp operation_execution_result(%{capture: %{summary: summary}}), do: summary
  defp operation_execution_result(%{result_summary: summary}), do: summary
  defp operation_execution_result(%{error: error}), do: error
  defp operation_execution_result(%{reason: reason}), do: reason
  defp operation_execution_result(_result), do: ""

  defp print_reconciliation_refs(reconciliation) do
    unless reconciliation.current_unobserved == [] do
      IO.puts("")
      IO.puts("current unobserved")
      print_reconciliation_table(reconciliation.current_unobserved)
    end

    unless reconciliation.observed_missing == [] do
      IO.puts("")
      IO.puts("observed missing")
      print_reconciliation_table(reconciliation.observed_missing)
    end
  end

  defp print_reconciliation_table(rows) do
    printable =
      Enum.map(rows, fn row ->
        [
          row.ref,
          row.host,
          row.type,
          row.state,
          row.kind,
          row.agent_name,
          Map.get(row, :work_state, ""),
          Map.get(row, :ssh_target, ""),
          Map.get(row, :actions, "")
        ]
      end)

    print_table(
      ["REF", "HOST", "TYPE", "STATE", "KIND", "AGENT", "WORK", "SSH_TARGET", "ACTIONS"],
      printable
    )
  end

  defp print_workflow_summary(workflow) do
    IO.puts("workflow")
    IO.puts("clusters: #{workflow.clusters_total}")

    unless workflow.clusters == [] do
      rows =
        Enum.map(workflow.clusters, fn cluster ->
          [
            cluster.name,
            Integer.to_string(cluster.total),
            Integer.to_string(cluster.agents),
            Integer.to_string(cluster.ssh),
            Integer.to_string(cluster.tmux),
            Integer.to_string(cluster.active),
            Integer.to_string(cluster.sendable),
            Integer.to_string(cluster.adoptable),
            format_counts(cluster.by_work_state)
          ]
        end)

      print_table(
        ["CLUSTER", "TOTAL", "AGENTS", "SSH", "TMUX", "ACTIVE", "SEND", "ADOPT", "WORK"],
        rows
      )
    end

    unless workflow.remote_targets == [] do
      IO.puts("")
      IO.puts("remote targets")

      rows =
        Enum.map(workflow.remote_targets, fn target ->
          [
            target.target,
            Integer.to_string(target.total),
            Integer.to_string(target.active),
            Integer.to_string(target.probe),
            Integer.to_string(target.force_probe)
          ]
        end)

      print_table(["TARGET", "TOTAL", "ACTIVE", "PROBE", "FORCE"], rows)
    end

    unless workflow.recommendations == [] do
      IO.puts("")
      IO.puts("recommended actions")

      rows =
        Enum.map(workflow.recommendations, fn recommendation ->
          [
            recommendation.priority,
            recommendation.kind,
            recommendation.action,
            recommendation.ref,
            truncate(recommendation.target, 64),
            truncate(recommendation.reason, 96)
          ]
        end)

      print_table(["PRIORITY", "KIND", "ACTION", "REF", "TARGET", "REASON"], rows)
    end
  end

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

  defp print_session_history([], opts) do
    if opts[:json] do
      print_json(%{observations: []})
    else
      IO.puts("no session observations")
    end
  end

  defp print_session_history(observations, opts) do
    if opts[:json] do
      print_json(%{observations: Enum.map(observations, &json_session_observation/1)})
    else
      rows =
        Enum.map(observations, fn observation ->
          [
            format_time(observation.inserted_at),
            observation.ref,
            observation.host,
            observation.type,
            observation.state,
            observation.kind,
            observation.work_state,
            observation.capture_status,
            truncate(observation.summary, 120)
          ]
        end)

      print_table(
        ["OBSERVED", "REF", "HOST", "TYPE", "STATE", "KIND", "WORK", "CAPTURE", "SUMMARY"],
        rows
      )
    end
  end

  defp print_session_changes([], opts) do
    if opts[:json] do
      print_json(%{changes: []})
    else
      IO.puts("no session changes")
    end
  end

  defp print_session_changes(changes, opts) do
    if opts[:json] do
      print_json(%{changes: Enum.map(changes, &json_session_change/1)})
    else
      rows =
        Enum.map(changes, fn change ->
          [
            format_time(change.observed_at),
            change.ref,
            change.host,
            change.type,
            change.kind,
            change.change,
            format_attention(change.needs_attention),
            previous_to_current(change.previous_work_state, change.work_state),
            previous_to_current(change.previous_capture_status, change.capture_status),
            Enum.join(change.changed_fields, ","),
            truncate(change.summary, 100)
          ]
        end)

      print_table(
        [
          "OBSERVED",
          "REF",
          "HOST",
          "TYPE",
          "KIND",
          "CHANGE",
          "ATTN",
          "WORK",
          "CAPTURE",
          "FIELDS",
          "SUMMARY"
        ],
        rows
      )
    end
  end

  defp print_session_observe(changes, opts) do
    if opts[:json] do
      print_json(%{
        saved: opts[:saved],
        changes: Enum.map(changes, &json_session_change/1)
      })
    else
      print_session_changes(changes, json: false)
      print_saved_count(opts[:saved])
    end
  end

  defp print_session_dossiers(%{dossiers: [], errors: []} = report, opts) do
    if opts[:json] do
      print_json(json_session_dossiers(report))
    else
      IO.puts("no session dossiers")
    end
  end

  defp print_session_dossiers(report, opts) do
    if opts[:json] do
      print_json(json_session_dossiers(report))
    else
      rows =
        Enum.map(report.dossiers, fn dossier ->
          [
            dossier.ref,
            dossier.control_mode,
            dossier.type,
            dossier.kind,
            dossier.work_state,
            dossier.next_action.action,
            dossier.directive_state,
            session_dossier_repo_summary(dossier.repo),
            truncate(dossier.project, 24),
            truncate(dossier.pane, 36),
            truncate(dossier.current_path, 48),
            truncate(dossier.task, 72)
          ]
        end)

      print_table(
        [
          "REF",
          "CONTROL",
          "TYPE",
          "KIND",
          "WORK",
          "NEXT",
          "DIRECTIVE",
          "REPO",
          "PROJECT",
          "PANE",
          "PATH",
          "TASK"
        ],
        rows
      )

      IO.puts("")
      print_summary_counts("observation refresh", report.observation_refresh)

      unless report.errors == [] do
        IO.puts("")
        print_summary_errors(report.errors)
      end
    end
  end

  defp print_session_queues(%{queues: [], errors: []} = report, opts) do
    if opts[:json] do
      print_json(json_session_queues(report))
    else
      IO.puts("no session queues")
    end
  end

  defp print_session_queues(report, opts) do
    if opts[:json] do
      print_json(json_session_queues(report))
    else
      rows =
        Enum.map(report.queues, fn queue ->
          [
            queue.action,
            Integer.to_string(queue.total),
            format_counts(queue.by_priority),
            format_counts(queue.by_safety),
            format_counts(queue.by_control),
            format_counts(queue.by_type),
            session_queue_refs(queue),
            session_queue_focus(queue)
          ]
        end)

      print_table(
        ["ACTION", "TOTAL", "PRIORITY", "SAFETY", "CONTROL", "TYPE", "REFS", "FOCUS"],
        rows
      )

      IO.puts("")
      print_summary_counts("observation refresh", report.observation_refresh)

      unless report.errors == [] do
        IO.puts("")
        print_summary_errors(report.errors)
      end
    end
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

  defp print_session_reconciliation(reconciliation, opts) do
    if opts[:json] do
      print_json(reconciliation)
    else
      IO.puts("session reconciliation")
      IO.puts("generated: #{format_time(reconciliation.generated_at)}")
      print_summary_counts("totals", reconciliation.totals)

      unless reconciliation.orphan_remote == [] do
        IO.puts("")
        IO.puts("orphan remote sessions")
        print_reconciliation_remote(reconciliation.orphan_remote)
      end

      unless reconciliation.local_without_remote == [] do
        IO.puts("")
        IO.puts("local without remote match")
        print_reconciliation_local(reconciliation.local_without_remote)
      end

      unless reconciliation.duplicate_paths == [] do
        IO.puts("")
        IO.puts("duplicate paths")
        print_reconciliation_duplicate_paths(reconciliation.duplicate_paths)
      end

      unless reconciliation.errors == [] do
        IO.puts("")
        print_summary_errors(reconciliation.errors)
      end
    end
  end

  defp print_reconciliation_remote(items) do
    rows =
      Enum.map(items, fn item ->
        [
          item.local_ref,
          item.ssh_target,
          item.tmux_server,
          item.session_name,
          truncate(item.current_path, 56),
          format_time(item.observed_at)
        ]
      end)

    print_table(["LOCAL_REF", "TARGET", "SERVER", "SESSION", "PATH", "OBSERVED"], rows)
  end

  defp print_reconciliation_local(items) do
    rows =
      Enum.map(items, fn item ->
        [
          item.ref,
          item.project,
          item.type,
          item.kind,
          item.state,
          item.prompt_status,
          truncate(item.path, 56),
          truncate(item.next_step, 48)
        ]
      end)

    print_table(["REF", "PROJECT", "TYPE", "KIND", "STATE", "PROMPT", "PATH", "NEXT"], rows)
  end

  defp print_reconciliation_duplicate_paths(items) do
    rows =
      Enum.map(items, fn item ->
        [
          truncate(item.path, 56),
          Enum.join(item.projects, ","),
          Enum.join(item.refs, ",")
        ]
      end)

    print_table(["PATH", "PROJECTS", "REFS"], rows)
  end

  defp print_monitor_scan(scan, opts) do
    if opts[:json] do
      print_json(json_monitor_scan(scan))
    else
      print_summary_counts("monitor", %{
        sessions: scan.sessions_total,
        events_saved: scan.events_saved,
        queues: scan.queues_total,
        watches: Map.get(scan, :watches_total, 0),
        watch_actions: Map.get(scan, :watch_actions_total, 0),
        ci_watches: Map.get(scan, :ci_watches_total, 0),
        delegations: Map.get(scan, :delegations_total, 0),
        delegation_reviews: Map.get(scan, :delegation_reviews_total, 0),
        delegation_long_running: get_in(scan, [:delegation_timing, :active, :long_running]) || 0,
        delegation_conflicts: get_in(scan, [:delegation_preflight, :conflicts_total]) || 0,
        notifications: Map.get(scan, :notifications_saved, 0),
        profiles: scan.profiles_total
      })

      IO.puts("")
      print_summary_counts("observation refresh", scan.observation_refresh)

      unless scan.events == [] do
        IO.puts("")
        IO.puts("new events")
        print_monitor_events(scan.events, json: false)
      end

      unless scan.queues == [] do
        IO.puts("")
        IO.puts("queues")
        print_monitor_queue_rows(scan.queues)
      end

      watch_updates = Map.get(scan, :watch_updates, [])

      unless watch_updates == [] do
        IO.puts("")
        IO.puts("watch updates")
        print_watch_updates(watch_updates)
      end

      watch_actions = Map.get(scan, :watch_actions, [])

      unless watch_actions == [] do
        IO.puts("")
        IO.puts("watch actions")
        print_watch_actions(watch_actions)
      end

      ci_watch_updates = Map.get(scan, :ci_watch_updates, [])

      unless ci_watch_updates == [] do
        IO.puts("")
        IO.puts("CI watch updates")
        print_ci_watch_updates(ci_watch_updates)
      end

      notifications = Map.get(scan, :notifications, [])

      unless notifications == [] do
        IO.puts("")
        IO.puts("notifications")
        print_notifications(notifications, json: false)
      end

      unless scan.errors == [] do
        IO.puts("")
        print_summary_errors(scan.errors)
      end
    end
  end

  defp print_orchestrate_report(report, opts) do
    if opts[:json] do
      print_json(json_orchestrate_report(report))
    else
      IO.puts("generated #{format_time(report.generated_at)}")
      IO.puts("consumer #{report.consumer}")
      IO.puts("mode #{report.mode}")
      IO.puts("")

      print_summary_counts("scan", %{
        sessions: report.scan.sessions_total,
        events_saved: report.scan.events_saved,
        queues: report.scan.queues_total,
        watches: Map.get(report.scan, :watches_total, 0),
        watch_actions: Map.get(report.scan, :watch_actions_total, 0),
        ci_watches: Map.get(report.scan, :ci_watches_total, 0),
        delegations: Map.get(report.scan, :delegations_total, 0),
        delegation_reviews: Map.get(report.scan, :delegation_reviews_total, 0),
        delegation_long_running:
          get_in(report.scan, [:delegation_timing, :active, :long_running]) || 0,
        delegation_conflicts: get_in(report.scan, [:delegation_preflight, :conflicts_total]) || 0,
        notifications: Map.get(report.scan, :notifications_saved, 0),
        profiles: report.scan.profiles_total
      })

      IO.puts("")

      print_summary_counts("inbox", %{
        unread: report.inbox.unread_total,
        matching_unread: report.inbox.matching_unread_total,
        returned: report.inbox.returned,
        latest_event: report.inbox.latest_event_id
      })

      IO.puts("")
      print_orchestrator_decisions(report.decisions)
      IO.puts("")
      print_operation_execution(report.execution)

      if report.cursor do
        IO.puts("")
        print_monitor_cursor(report.cursor)
      end

      unless report.errors == [] do
        IO.puts("")
        print_summary_errors(report.errors)
      end
    end
  end

  defp print_orchestrator_decisions([]), do: IO.puts("decisions: none")

  defp print_orchestrator_decisions(decisions) do
    rows =
      Enum.map(decisions, fn decision ->
        [
          decision.id,
          decision.status,
          decision.safety,
          decision.action,
          decision.ref,
          Map.get(decision, :state, ""),
          Map.get(decision, :prompt_status, ""),
          decision |> Map.get(:event_ids, []) |> Enum.join(",") |> truncate(32),
          truncate(decision.reason, 88),
          truncate(Map.get(decision, :message, ""), 72)
        ]
      end)

    IO.puts("decisions")

    print_table(
      [
        "ID",
        "STATUS",
        "SAFETY",
        "ACTION",
        "REF",
        "STATE",
        "PROMPT",
        "EVENTS",
        "REASON",
        "MESSAGE"
      ],
      rows
    )
  end

  defp print_monitor_queue_rows(queues) do
    rows =
      Enum.map(queues, fn queue ->
        [
          queue.action,
          Integer.to_string(queue.total),
          format_counts(queue.by_priority),
          format_counts(queue.by_safety),
          format_counts(queue.by_control),
          session_queue_refs(queue),
          session_queue_focus(queue)
        ]
      end)

    print_table(["ACTION", "TOTAL", "PRIORITY", "SAFETY", "CONTROL", "REFS", "FOCUS"], rows)
  end

  defp print_watch_updates(updates) do
    rows =
      Enum.map(updates, fn update ->
        [
          update.watch.watch_id,
          update.previous_status,
          update.status,
          update.watch.mode,
          update.watch.ref,
          truncate(update.watch.goal, 44),
          truncate(update.summary, 72)
        ]
      end)

    print_table(["WATCH", "FROM", "TO", "MODE", "REF", "GOAL", "SUMMARY"], rows)
  end

  defp print_watch_actions(actions) do
    rows =
      Enum.map(actions, fn action ->
        [
          action.watch_id,
          action.status,
          action.action,
          action.ref,
          Map.get(action, :prompt_status, ""),
          truncate(Map.get(action, :reason, ""), 40),
          truncate(action.result_summary, 72)
        ]
      end)

    print_table(["WATCH", "STATUS", "ACTION", "REF", "PROMPT", "REASON", "SUMMARY"], rows)
  end

  defp print_ci_watch_updates(updates) do
    rows =
      Enum.map(updates, fn update ->
        [
          update.watch.watch_id,
          update.previous_status,
          update.status,
          update.watch.mode,
          update.watch.repo,
          "##{update.watch.pr_number}",
          update.watch.ref,
          truncate(update.summary, 72)
        ]
      end)

    print_table(["WATCH", "FROM", "TO", "MODE", "REPO", "PR", "REF", "SUMMARY"], rows)
  end

  defp print_monitor_events([], opts) do
    if opts[:json] do
      print_json(%{events: []})
    else
      IO.puts("no monitor events")
    end
  end

  defp print_monitor_events(events, opts) do
    if opts[:json] do
      print_json(%{events: Enum.map(events, &json_monitor_event/1)})
    else
      rows =
        Enum.map(events, fn event ->
          [
            Integer.to_string(event.id),
            format_time(event.inserted_at),
            event.kind,
            event.severity,
            event.ref,
            event.project,
            event.work_state,
            event.action,
            truncate(event.summary, 120)
          ]
        end)

      print_table(
        ["ID", "TIME", "KIND", "SEVERITY", "REF", "PROJECT", "WORK", "ACTION", "SUMMARY"],
        rows
      )
    end
  end

  defp print_monitor_unread(report, opts) do
    if opts[:json] do
      print_json(json_monitor_unread(report))
    else
      print_summary_counts("events", %{
        unread: report.unread_total,
        matching_unread: report.matching_unread_total,
        returned: report.returned,
        latest_event: report.latest_event_id
      })

      IO.puts("")
      print_monitor_cursor(report.cursor)

      IO.puts("")
      print_monitor_events(report.events, json: false)
    end
  end

  defp print_monitor_ack(cursor, opts) do
    if opts[:json] do
      print_json(%{cursor: json_monitor_cursor(cursor)})
    else
      IO.puts("acknowledged #{cursor.consumer} through event #{cursor.last_event_id}")
      print_monitor_cursor(cursor)
    end
  end

  defp print_monitor_event_status(status, opts) do
    if opts[:json] do
      print_json(json_monitor_event_status(status))
    else
      rows = [
        ["consumer", status.consumer],
        ["cursor_source", Map.get(status.cursor, :source, "-")],
        ["last_event_id", Integer.to_string(Map.get(status.cursor, :last_event_id, 0))],
        ["latest_event_id", Integer.to_string(status.latest_event_id)],
        ["unread_total", Integer.to_string(status.unread_total)],
        ["caught_up", inspect(status.caught_up)],
        ["last_seen_at", format_time(Map.get(status.cursor, :last_seen_at))],
        ["updated_at", format_time(Map.get(status.cursor, :updated_at))]
      ]

      print_table(["FIELD", "VALUE"], rows)

      if status.latest_event do
        IO.puts("")
        IO.puts("latest event")
        print_monitor_events([status.latest_event], json: false)
      end
    end
  end

  defp print_monitor_cursor(cursor) do
    rows = [
      ["consumer", Map.get(cursor, :consumer, "-")],
      ["source", Map.get(cursor, :source, "-")],
      ["last_event_id", Integer.to_string(Map.get(cursor, :last_event_id, 0))],
      ["last_seen_at", format_time(Map.get(cursor, :last_seen_at))],
      ["updated_at", format_time(Map.get(cursor, :updated_at))]
    ]

    print_table(["CURSOR", "VALUE"], rows)
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

  defp print_stale_sessions([], opts) do
    if opts[:json] do
      print_json(%{stale: []})
    else
      IO.puts("no stale session observations")
    end
  end

  defp print_stale_sessions(stale_sessions, opts) do
    if opts[:json] do
      print_json(%{stale: Enum.map(stale_sessions, &json_stale_session/1)})
    else
      rows =
        Enum.map(stale_sessions, fn stale ->
          [
            stale.ref,
            stale.host,
            stale.type,
            stale.kind,
            stale.work_state,
            stale.capture_status,
            Integer.to_string(stale.stale_seconds),
            format_time(stale.observed_at),
            format_attention(stale.needs_attention),
            truncate(stale.summary, 100)
          ]
        end)

      print_table(
        [
          "REF",
          "HOST",
          "TYPE",
          "KIND",
          "WORK",
          "CAPTURE",
          "STALE_S",
          "OBSERVED",
          "ATTN",
          "SUMMARY"
        ],
        rows
      )
    end
  end

  defp print_broadcast_report(report, opts) do
    if opts[:json] do
      print_json(%{
        dry_run: report.dry_run,
        targets: report.targets,
        errors: Enum.map(report.errors, &json_error/1)
      })
    else
      print_broadcast_targets(report.targets, report.dry_run)
      print_broadcast_errors(report.errors)
    end
  end

  defp print_broadcast_targets([], true), do: IO.puts("no sendable targets")
  defp print_broadcast_targets([], false), do: IO.puts("no targets sent")

  defp print_broadcast_targets(targets, dry_run?) do
    if dry_run?, do: IO.puts("dry run: pass --yes to send")

    rows =
      Enum.map(targets, fn target ->
        [
          target.ref,
          target.status,
          target.host,
          target.type,
          target.kind,
          target.work_state || "",
          session_target(target),
          Map.get(target, :directive_id, ""),
          Map.get(target, :error, ""),
          truncate(target.summary, 100)
        ]
      end)

    print_table(
      [
        "REF",
        "STATUS",
        "HOST",
        "TYPE",
        "KIND",
        "WORK",
        "TARGET",
        "DIRECTIVE",
        "ERROR",
        "SUMMARY"
      ],
      rows
    )
  end

  defp print_broadcast_errors([]), do: :ok

  defp print_broadcast_errors(errors) do
    IO.puts("")

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

  defp print_sessions_remote_candidates(candidates, opts) do
    if opts[:json] do
      print_json(%{candidates: candidates})
    else
      print_pane_probe_candidates(candidates)
    end
  end

  defp print_sessions_remote_probes(probes, opts) do
    if opts[:json] do
      print_json(%{probes: Enum.map(probes, &json_remote_probe/1)})
    else
      print_pane_probe_scan(probes)
    end
  end

  defp print_sessions_snapshot_table(sessions, errors) do
    unless sessions == [] do
      rows =
        Enum.map(sessions, fn session ->
          [
            session.ref,
            session.type,
            session.state,
            session.kind,
            session.ssh_target,
            session_pane(session),
            session.actions,
            capture_status(session),
            capture_work_state(session),
            capture_summary(session)
          ]
        end)

      print_table(
        [
          "REF",
          "TYPE",
          "STATE",
          "KIND",
          "SSH_TARGET",
          "PANE",
          "ACTIONS",
          "CAPTURE",
          "WORK",
          "LAST_LINE"
        ],
        rows
      )
    end

    unless errors == [] do
      if sessions != [], do: IO.puts("")

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
  end

  defp session_pane(%{server: server, session: session, window: window, pane: pane})
       when server not in [nil, ""] and session not in [nil, ""] do
    "#{server}/#{session}:#{window}.#{pane}"
  end

  defp session_pane(_session), do: ""

  defp session_target(%{tmux_server: server, session_name: session, window: window, pane: pane})
       when server not in [nil, ""] and session not in [nil, ""] do
    "#{server}/#{session}:#{window}.#{pane}"
  end

  defp session_target(_target), do: ""

  defp capture_status(%{capture: %{status: status}}), do: status
  defp capture_status(_session), do: ""

  defp capture_work_state(%{capture: %{work_state: work_state}}), do: work_state
  defp capture_work_state(_session), do: ""

  defp capture_summary(%{capture: %{output: output}}) when is_binary(output) do
    output
    |> JX.SessionStatus.summary(160)
  end

  defp capture_summary(%{capture: %{error: error}}), do: truncate(error, 160)
  defp capture_summary(_session), do: ""

  defp maybe_compact_snapshot(report, true) do
    %{report | sessions: Enum.map(report.sessions, &compact_snapshot_session/1)}
  end

  defp maybe_compact_snapshot(report, _compact?), do: report

  defp maybe_put_saved(report, nil), do: report
  defp maybe_put_saved(report, saved), do: Map.put(report, :saved, saved)

  defp compact_snapshot_session(session) do
    capture = Map.get(session, :capture, %{})

    compact_capture =
      capture
      |> Map.drop([:output])
      |> Map.put_new(
        :summary,
        JX.SessionStatus.summary(Map.get(capture, :output, ""))
      )

    Map.put(session, :capture, compact_capture)
  end

  defp json_error(error) do
    %{
      host: Map.get(error, :host, ""),
      transport: Map.get(error, :transport, ""),
      subsystem: Map.get(error, :subsystem, ""),
      error: format_error(Map.get(error, :error, ""))
    }
  end

  defp json_sessions_summary(summary) do
    %{
      generated_at: format_time(summary.generated_at),
      registry: summary.registry,
      current: summary.current,
      observations: summary.observations,
      observation_refresh: summary.observation_refresh,
      reconciliation: json_reconciliation(summary.reconciliation),
      remote: summary.remote,
      workflow: summary.workflow,
      attention: Enum.map(summary.attention, &json_session_change/1),
      stale: Enum.map(summary.stale, &json_stale_session/1),
      errors: Enum.map(summary.errors, &json_error/1)
    }
  end

  defp json_operation(operation) do
    %{
      generated_at: format_time(operation.generated_at),
      mode: operation.mode,
      observation_refresh: operation.observation_refresh,
      state: %{
        current: operation.state.current,
        observations: operation.state.observations,
        reconciliation: json_reconciliation(operation.state.reconciliation),
        remote: operation.state.remote,
        workflow: operation.state.workflow
      },
      attention: Enum.map(operation.attention, &json_session_change/1),
      stale: Enum.map(operation.stale, &json_stale_session/1),
      recommendations: operation.recommendations,
      safe_actions: operation.safe_actions,
      gated_actions: operation.gated_actions,
      manual_actions: operation.manual_actions,
      unknowns: json_operation_unknowns(operation.unknowns),
      execution: operation.execution,
      errors: Enum.map(operation.errors, &json_error/1)
    }
  end

  defp json_operation_unknowns(unknowns) do
    %{
      unobservable_agents: unknowns.unobservable_agents,
      current_unobserved: unknowns.current_unobserved,
      observed_missing:
        Enum.map(unknowns.observed_missing, fn row ->
          Map.update(row, :observed_at, nil, &format_time/1)
        end)
    }
  end

  defp json_reconciliation(reconciliation) do
    %{
      current_observed_total: reconciliation.current_observed_total,
      current_unobserved_total: reconciliation.current_unobserved_total,
      observed_missing_total: reconciliation.observed_missing_total,
      current_unobserved: reconciliation.current_unobserved,
      observed_missing:
        Enum.map(reconciliation.observed_missing, fn row ->
          Map.update(row, :observed_at, nil, &format_time/1)
        end)
    }
  end

  defp json_session_observation(observation) do
    %{
      id: observation.id,
      ref: observation.ref,
      host: observation.host,
      transport: observation.transport,
      type: observation.type,
      state: observation.state,
      kind: observation.kind,
      agent_name: observation.agent_name,
      task_id: observation.task_id,
      tmux_server: observation.tmux_server,
      session_name: observation.session_name,
      window: observation.window,
      pane: observation.pane,
      pid: observation.pid,
      ssh_target: observation.ssh_target,
      work_state: observation.work_state,
      capture_status: observation.capture_status,
      summary: observation.summary,
      snapshot: observation_snapshot(observation.snapshot),
      inserted_at: format_time(observation.inserted_at)
    }
  end

  defp json_session_change(change) do
    %{
      ref: change.ref,
      host: change.host,
      transport: change.transport,
      type: change.type,
      state: change.state,
      kind: change.kind,
      agent_name: change.agent_name,
      task_id: change.task_id,
      tmux_server: change.tmux_server,
      session_name: change.session_name,
      window: change.window,
      pane: change.pane,
      pid: change.pid,
      ssh_target: change.ssh_target,
      work_state: change.work_state,
      previous_work_state: change.previous_work_state,
      capture_status: change.capture_status,
      previous_capture_status: change.previous_capture_status,
      summary: change.summary,
      previous_summary: change.previous_summary,
      observed_at: format_time(change.observed_at),
      previous_observed_at: format_time(change.previous_observed_at),
      elapsed_seconds: change.elapsed_seconds,
      change: change.change,
      changed_fields: change.changed_fields,
      needs_attention: change.needs_attention
    }
  end

  defp json_stale_session(stale) do
    %{
      ref: stale.ref,
      host: stale.host,
      transport: stale.transport,
      type: stale.type,
      state: stale.state,
      kind: stale.kind,
      agent_name: stale.agent_name,
      task_id: stale.task_id,
      tmux_server: stale.tmux_server,
      session_name: stale.session_name,
      window: stale.window,
      pane: stale.pane,
      pid: stale.pid,
      ssh_target: stale.ssh_target,
      work_state: stale.work_state,
      capture_status: stale.capture_status,
      summary: stale.summary,
      observed_at: format_time(stale.observed_at),
      stale_seconds: stale.stale_seconds,
      needs_attention: stale.needs_attention
    }
  end

  defp json_session_dossiers(report) do
    %{
      generated_at: format_time(report.generated_at),
      observed: report.observed,
      observation_refresh: report.observation_refresh,
      total: report.total,
      dossiers: report.dossiers,
      errors: Enum.map(report.errors, &json_error/1)
    }
  end

  defp json_session_queues(report) do
    %{
      generated_at: format_time(report.generated_at),
      observed: report.observed,
      observation_refresh: report.observation_refresh,
      total: report.total,
      queues_total: report.queues_total,
      queues: report.queues,
      errors: Enum.map(report.errors, &json_error/1)
    }
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

  defp json_orchestrator_inbox(inbox) do
    %{
      generated_at: format_time(inbox.generated_at),
      observed: inbox.observed,
      observation_refresh: inbox.observation_refresh,
      total: inbox.total,
      sections: inbox.sections,
      errors: Enum.map(inbox.errors, &json_error/1)
    }
  end

  defp json_orchestrator_review(review) do
    %{
      generated_at: format_time(review.generated_at),
      ref: review.ref,
      observed: review.observed,
      observation_refresh: review.observation_refresh,
      profile: review.profile,
      latest_observation: json_latest_observation(review.latest_observation),
      recommendation: review.recommendation,
      commands: review.commands,
      errors: Enum.map(review.errors, &json_error/1)
    }
  end

  defp json_latest_observation(nil), do: nil

  defp json_latest_observation(observation) do
    Map.update!(observation, :inserted_at, &format_time/1)
  end

  defp json_orchestrator_decision(result) do
    %{
      ref: result.ref,
      action: result.action,
      result_summary: result.result_summary
    }
  end

  defp json_monitor_scan(scan) do
    %{
      generated_at: format_time(scan.generated_at),
      observed: scan.observed,
      observation_refresh: scan.observation_refresh,
      sessions_total: scan.sessions_total,
      events_saved: scan.events_saved,
      events: Enum.map(scan.events, &json_monitor_event/1),
      queues_total: scan.queues_total,
      queues: scan.queues,
      watches_total: Map.get(scan, :watches_total, 0),
      watch_updates:
        scan
        |> Map.get(:watch_updates, [])
        |> Enum.map(&json_watch_update/1),
      watch_actions_total: Map.get(scan, :watch_actions_total, 0),
      watch_actions:
        scan
        |> Map.get(:watch_actions, [])
        |> Enum.map(&json_watch_action/1),
      ci_watches_total: Map.get(scan, :ci_watches_total, 0),
      ci_watch_updates:
        scan
        |> Map.get(:ci_watch_updates, [])
        |> Enum.map(&json_ci_watch_update/1),
      wake_triggers_total: Map.get(scan, :wake_triggers_total, 0),
      wake_notifications_saved: Map.get(scan, :wake_notifications_saved, 0),
      wake_triggers:
        scan
        |> Map.get(:wake_triggers, [])
        |> Enum.map(&json_wake_trigger_run/1),
      call_handoffs_total: Map.get(scan, :call_handoffs_total, 0),
      call_handoffs:
        scan
        |> Map.get(:call_handoffs, [])
        |> Enum.map(&json_call_handoff/1),
      delegations_total: Map.get(scan, :delegations_total, 0),
      delegations:
        scan
        |> Map.get(:delegations, [])
        |> Enum.map(&json_delegation/1),
      delegation_reviews_total: Map.get(scan, :delegation_reviews_total, 0),
      delegation_reviews: Map.get(scan, :delegation_reviews, []),
      delegation_preflight: Map.get(scan, :delegation_preflight, %{}),
      delegation_timing: Map.get(scan, :delegation_timing, %{}),
      notifications_saved: Map.get(scan, :notifications_saved, 0),
      notifications:
        scan
        |> Map.get(:notifications, [])
        |> Enum.map(&json_notification/1),
      profiles_total: scan.profiles_total,
      profiles: scan.profiles,
      errors: Enum.map(scan.errors, &json_error/1)
    }
  end

  defp json_orchestrate_report(report) do
    %{
      generated_at: format_time(report.generated_at),
      consumer: report.consumer,
      mode: report.mode,
      scan: json_monitor_scan(report.scan),
      inbox: %{
        cursor: json_monitor_cursor(report.inbox.cursor),
        latest_event_id: report.inbox.latest_event_id,
        unread_total: report.inbox.unread_total,
        matching_unread_total: report.inbox.matching_unread_total,
        returned: report.inbox.returned,
        events: Enum.map(report.inbox.events, &json_monitor_event/1)
      },
      decisions: report.decisions,
      action_queue: Map.get(report, :action_queue),
      execution: report.execution,
      heartbeat: Map.get(report, :heartbeat),
      cursor: maybe_json_monitor_cursor(report.cursor),
      errors: Enum.map(report.errors, &json_error/1)
    }
  end

  defp json_monitor_event(event) do
    %{
      id: event.id,
      event_id: event.event_id,
      kind: event.kind,
      severity: event.severity,
      ref: event.ref,
      project: event.project,
      session_type: event.session_type,
      session_kind: event.session_kind,
      control_mode: event.control_mode,
      work_state: event.work_state,
      action: event.action,
      summary: event.summary,
      fingerprint: event.fingerprint,
      payload: observation_snapshot(event.payload),
      inserted_at: format_time(event.inserted_at)
    }
  end

  defp json_monitor_unread(report) do
    %{
      consumer: report.consumer,
      cursor: json_monitor_cursor(report.cursor),
      latest_event_id: report.latest_event_id,
      unread_total: report.unread_total,
      matching_unread_total: report.matching_unread_total,
      returned: report.returned,
      events: Enum.map(report.events, &json_monitor_event/1)
    }
  end

  defp json_monitor_event_status(status) do
    %{
      consumer: status.consumer,
      cursor: json_monitor_cursor(status.cursor),
      latest_event_id: status.latest_event_id,
      unread_total: status.unread_total,
      caught_up: status.caught_up,
      latest_event: maybe_json_monitor_event(status.latest_event)
    }
  end

  defp json_monitor_cursor(cursor) do
    %{
      consumer: Map.get(cursor, :consumer),
      source: Map.get(cursor, :source),
      last_event_id: Map.get(cursor, :last_event_id, 0),
      last_seen_at: format_time(Map.get(cursor, :last_seen_at)),
      updated_at: format_time(Map.get(cursor, :updated_at))
    }
  end

  defp maybe_json_monitor_cursor(nil), do: nil
  defp maybe_json_monitor_cursor(cursor), do: json_monitor_cursor(cursor)

  defp maybe_json_monitor_event(nil), do: nil
  defp maybe_json_monitor_event(event), do: json_monitor_event(event)

  defp json_remote_probe(probe) do
    probe
    |> Map.update(:error, nil, &format_error/1)
    |> Map.update(:remote_sessions, [], fn sessions ->
      Enum.map(sessions, fn session ->
        %{
          server: session.server,
          session: session.session,
          created_at: format_time(session.created_at),
          attached: session.attached,
          windows: session.windows,
          current_path: session.current_path
        }
      end)
    end)
  end

  defp json_operation_execution(execution) do
    %{
      execution_id: execution.execution_id,
      requested: execution.requested,
      recommendation_id: execution.recommendation_id,
      action: execution.action,
      safety: execution.safety,
      ref: execution.ref,
      target: execution.target,
      status: execution.status,
      reason: execution.reason,
      error: execution.error,
      result_summary: execution.result_summary,
      result_snapshot: operation_execution_snapshot(execution.result_snapshot),
      inserted_at: format_time(execution.inserted_at)
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

  defp json_notification(notification) do
    %{
      notification_id: notification.notification_id,
      source_event_id: notification.source_event_id,
      kind: notification.kind,
      severity: notification.severity,
      status: notification.status,
      ref: notification.ref,
      project: notification.project,
      summary: notification.summary,
      payload: operation_execution_snapshot(notification.payload),
      acknowledged_at: format_time(notification.acknowledged_at),
      inserted_at: format_time(notification.inserted_at),
      updated_at: format_time(notification.updated_at)
    }
  end

  defp json_call_handoff(handoff) do
    %{
      handoff_id: handoff.handoff_id,
      surface: handoff.surface,
      status: handoff.status,
      project: handoff.project,
      ref: handoff.ref,
      title: handoff.title,
      summary: handoff.summary,
      operator_input: handoff.operator_input,
      decisions: decode_json_text(handoff.decisions),
      follow_ups: decode_json_text(handoff.follow_ups),
      brief_snapshot: decode_json_text(handoff.brief_snapshot),
      payload: decode_json_text(handoff.payload),
      closed_at: format_time(handoff.closed_at),
      inserted_at: format_time(handoff.inserted_at),
      updated_at: format_time(handoff.updated_at)
    }
  end

  defp json_delegation(delegation) do
    summary = JX.Delegations.delegation_summary(delegation)

    %{
      delegation_id: delegation.delegation_id,
      status: delegation.status,
      priority: delegation.priority,
      project: delegation.project,
      ref: delegation.ref,
      source: delegation.source,
      owner: delegation.owner,
      agent_kind: delegation.agent_kind,
      title: delegation.title,
      brief: delegation.brief,
      context: decode_json_text(delegation.context),
      constraints: decode_json_text(delegation.constraints),
      acceptance: decode_json_text(delegation.acceptance),
      verification: decode_json_text(delegation.verification),
      write_paths: decode_json_text(delegation.write_paths),
      forbidden_paths: decode_json_text(delegation.forbidden_paths),
      lint_warnings: decode_json_text(delegation.lint_warnings),
      evidence: decode_json_text(delegation.evidence),
      residual_risks: decode_json_text(delegation.residual_risks),
      review: summary.review,
      timing: summary.timing,
      integration_status: delegation.integration_status,
      integration_summary: delegation.integration_summary,
      reviewed_by: delegation.reviewed_by,
      reviewed_at: format_time(delegation.reviewed_at),
      worker_summary: delegation.worker_summary,
      artifacts: decode_json_text(delegation.artifacts),
      payload: decode_json_text(delegation.payload),
      claimed_at: format_time(delegation.claimed_at),
      completed_at: format_time(delegation.completed_at),
      inserted_at: format_time(delegation.inserted_at),
      updated_at: format_time(delegation.updated_at)
    }
  end

  defp json_orchestrator_heartbeat(heartbeat) do
    snapshot = operation_execution_snapshot(heartbeat.scan_snapshot)

    %{
      daemon_key: heartbeat.daemon_key,
      consumer: heartbeat.consumer,
      session_name: heartbeat.session_name,
      status: heartbeat.status,
      mode: heartbeat.mode,
      last_scan_at: format_time(heartbeat.last_scan_at),
      last_decision_at: format_time(heartbeat.last_decision_at),
      last_error: heartbeat.last_error,
      next_wake_at: format_time(heartbeat.next_wake_at),
      guidance: Map.get(snapshot, "guidance", %{}),
      scan_snapshot: snapshot,
      updated_at: format_time(heartbeat.updated_at)
    }
  end

  defp json_orchestrator_health(health) do
    %{
      generated_at: format_time(health.generated_at),
      status: health.status,
      stale_after_seconds: health.stale_after_seconds,
      heartbeats_total: health.heartbeats_total,
      alerts_total: health.alerts_total,
      alerts: Enum.map(health.alerts, &json_orchestrator_health_alert/1),
      heartbeats: Enum.map(health.heartbeats, &json_orchestrator_heartbeat/1)
    }
  end

  defp json_orchestrator_health_alert(alert) do
    %{
      kind: Map.get(alert, :kind, ""),
      reason: Map.get(alert, :reason, ""),
      severity: Map.get(alert, :severity, ""),
      daemon_key: Map.get(alert, :daemon_key, ""),
      consumer: Map.get(alert, :consumer, ""),
      session_name: Map.get(alert, :session_name, ""),
      status: Map.get(alert, :status, ""),
      mode: Map.get(alert, :mode, ""),
      last_scan_at: format_time(Map.get(alert, :last_scan_at)),
      last_decision_at: format_time(Map.get(alert, :last_decision_at)),
      last_error: Map.get(alert, :last_error, ""),
      next_wake_at: format_time(Map.get(alert, :next_wake_at)),
      overdue_seconds: Map.get(alert, :overdue_seconds),
      summary: Map.get(alert, :summary, "")
    }
  end

  defp heartbeat_guidance(heartbeat) do
    case operation_execution_snapshot(heartbeat.scan_snapshot) do
      %{"guidance" => guidance} -> guidance
      _other -> %{}
    end
  end

  defp json_session_control(control) do
    %{
      ref: control.ref,
      mode: control.mode,
      project: control.project,
      note: control.note,
      host: control.host,
      type: control.type,
      kind: control.kind,
      ssh_target: control.ssh_target,
      tmux_server: control.tmux_server,
      session_name: control.session_name,
      window: control.window,
      pane: control.pane,
      pid: control.pid,
      current_path: control.current_path,
      title: control.title,
      last_seen_at: format_time(control.last_seen_at),
      updated_at: format_time(control.updated_at)
    }
  end

  defp json_session_watch(watch) do
    %{
      watch_id: watch.watch_id,
      ref: watch.ref,
      status: watch.status,
      mode: watch.mode,
      project: watch.project,
      session_type: watch.session_type,
      session_kind: watch.session_kind,
      goal: watch.goal,
      success_pattern: watch.success_pattern,
      blocker_pattern: watch.blocker_pattern,
      prompt: watch.prompt,
      last_summary: watch.last_summary,
      result_summary: watch.result_summary,
      last_observed_at: format_time(watch.last_observed_at),
      completed_at: format_time(watch.completed_at),
      inserted_at: format_time(watch.inserted_at),
      updated_at: format_time(watch.updated_at)
    }
  end

  defp json_ci_watch(watch) do
    %{
      watch_id: watch.watch_id,
      repo: watch.repo,
      pr_number: watch.pr_number,
      ref: watch.ref,
      project: watch.project,
      status: watch.status,
      mode: watch.mode,
      goal: watch.goal,
      head_sha: Map.get(watch, :head_sha, ""),
      last_head_sha: Map.get(watch, :last_head_sha, ""),
      success_prompt: watch.success_prompt,
      failure_prompt: watch.failure_prompt,
      last_overall: watch.last_overall,
      last_summary: watch.last_summary,
      last_digest: decode_json_text(watch.last_digest),
      last_checked_at: format_time(watch.last_checked_at),
      last_head_checked_at: format_time(Map.get(watch, :last_head_checked_at)),
      completed_at: format_time(watch.completed_at),
      inserted_at: format_time(watch.inserted_at),
      updated_at: format_time(watch.updated_at)
    }
  end

  defp json_wake_trigger(trigger) do
    %{
      trigger_id: trigger.trigger_id,
      name: trigger.name,
      status: trigger.status,
      message: trigger.message,
      project: trigger.project,
      ref: trigger.ref,
      severity: trigger.severity,
      schedule: trigger.schedule,
      every_seconds: trigger.every_seconds,
      next_run_at: format_time(trigger.next_run_at),
      last_run_at: format_time(trigger.last_run_at),
      run_count: trigger.run_count,
      last_result: trigger.last_result,
      inserted_at: format_time(trigger.inserted_at),
      updated_at: format_time(trigger.updated_at)
    }
  end

  defp json_wake_trigger_run(run) do
    %{
      status: run.status,
      result: run.result,
      trigger: json_wake_trigger(run.trigger),
      wake: maybe_json_wake_result(run.wake),
      errors: Enum.map(Map.get(run, :errors, []), &json_error/1)
    }
  end

  defp json_watch_update(update) do
    %{
      watch: json_session_watch(update.watch),
      previous_status: update.previous_status,
      status: update.status,
      changed: update.changed?,
      profile_action: maybe_json_watch_action(Map.get(update, :profile_action)),
      summary: update.summary,
      ref: update.watch.ref
    }
  end

  defp json_ci_watch_update(update) do
    %{
      watch: json_ci_watch(update.watch),
      previous_status: update.previous_status,
      status: update.status,
      changed: update.changed?,
      profile_action: maybe_json_watch_action(Map.get(update, :profile_action)),
      summary: update.summary,
      ref: update.watch.ref,
      digest: update.digest
    }
  end

  defp maybe_json_watch_action(nil), do: nil
  defp maybe_json_watch_action(action), do: json_watch_action(action)

  defp json_watch_action(action) do
    %{
      watch_id: action.watch_id,
      ref: action.ref,
      action: action.action,
      status: action.status,
      prompt_status: Map.get(action, :prompt_status),
      reason: Map.get(action, :reason),
      result_summary: action.result_summary,
      error: Map.get(action, :error)
    }
  end

  defp json_work_board(board) do
    %{
      generated_at: format_time(board.generated_at),
      observed: board.observed,
      total: board.total,
      items: board.items,
      delegation_reviews_total: Map.get(board, :delegation_reviews_total, 0),
      delegation_reviews: Map.get(board, :delegation_reviews, []),
      delegation_timing: Map.get(board, :delegation_timing, %{}),
      errors: Enum.map(board.errors, &json_error/1)
    }
  end

  defp json_remote_observation(observation) do
    %{
      local_ref: observation.local_ref,
      ssh_target: observation.ssh_target,
      registered_host: observation.registered_host,
      tmux_server: observation.tmux_server,
      session_name: observation.session_name,
      created_at: format_time(observation.created_at),
      attached: observation.attached,
      windows: observation.windows,
      current_path: observation.current_path,
      recommendation_id: observation.recommendation_id,
      probe_target: observation.probe_target,
      observed_at: format_time(observation.inserted_at)
    }
  end

  defp operation_execution_record_result(%{error: error}) when error not in [nil, ""], do: error

  defp operation_execution_record_result(%{reason: reason}) when reason not in [nil, ""],
    do: reason

  defp operation_execution_record_result(%{result_summary: summary}), do: summary

  defp operation_execution_snapshot(snapshot) do
    snapshot
    |> observation_snapshot()
    |> redact_operation_snapshot()
  end

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

  defp observation_snapshot(snapshot) do
    case Jason.decode(snapshot) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> snapshot
    end
  end

  defp decode_json_text(value) when value in [nil, ""], do: %{}

  defp decode_json_text(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end

  defp print_saved_count(nil), do: :ok
  defp print_saved_count(count), do: IO.puts("saved #{count} observations")

  defp print_usage_modes(modes, json: true), do: print_json(%{modes: modes})

  defp print_usage_modes(modes, json: false) do
    IO.puts("jx usage modes")

    Enum.each(modes, fn mode ->
      IO.puts("")
      IO.puts("#{mode.id} - #{mode.title}")
      IO.puts("  #{mode.intent}")
      IO.puts("  Best for: #{Enum.join(mode.best_for, "; ")}")
      IO.puts("  Safety: #{mode.safety}")
      IO.puts("  Commands:")
      Enum.each(mode.commands, &IO.puts("    #{&1}"))
    end)
  end

  defp print_usage_mode_playbook(playbook, json: true), do: print_json(%{playbook: playbook})

  defp print_usage_mode_playbook(playbook, json: false) do
    IO.puts("mode #{playbook.id} - #{playbook.title}")
    IO.puts("intent: #{playbook.intent}")
    IO.puts("entrypoint: #{playbook.entrypoint}")
    IO.puts("safety: #{playbook.safety}")
    print_labeled_lines("best for", playbook.best_for)
    print_labeled_lines("checks", playbook.checks)
    print_labeled_lines("signals", playbook.signals)
    print_labeled_lines("switch when", playbook.switch_when)
    IO.puts("commands:")
    Enum.each(playbook.commands, &IO.puts("  #{&1}"))
    IO.puts("handoff: #{playbook.handoff}")
  end

  defp print_labeled_lines(label, lines) do
    IO.puts("#{label}:")
    Enum.each(lines, &IO.puts("  #{&1}"))
  end

  defp print_next_step(next_step, json: true), do: print_json(next_step)

  defp print_next_step(next_step, json: false) do
    IO.puts("next")
    IO.puts("action: #{next_step.next}")
    IO.puts("mode: #{next_step.mode} - #{next_step.mode_title}")
    IO.puts("command: #{next_step.command}")
    IO.puts("reason: #{next_step.reason}")

    if next_step.focus_refs != [] do
      IO.puts("focus refs: #{Enum.join(next_step.focus_refs, ", ")}")
    end

    orchestrator = next_step.orchestrator || %{}
    status = Map.get(orchestrator, :status, "unknown")
    mode = Map.get(orchestrator, :mode, "")
    consumer = Map.get(orchestrator, :consumer, "")
    label = [status, consumer, mode] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")
    IO.puts("orchestrator: #{label}")
  end

  defp print_wake(result, json: true), do: print_json(json_wake_result(result))

  defp print_wake(result, json: false) do
    IO.puts("wake #{result.wake_id}")

    case result.events do
      [event | _rest] ->
        IO.puts("event: #{event.event_id} #{event.kind} #{event.severity}")
        IO.puts("summary: #{event.summary}")

      [] ->
        IO.puts("event: duplicate latest wake; nothing saved")
    end

    IO.puts("notifications saved: #{result.notifications.saved}")

    unless result.notifications.errors == [] do
      IO.puts("notification errors: #{Enum.join(result.notifications.errors, "; ")}")
    end
  end

  defp maybe_json_wake_result(nil), do: nil
  defp maybe_json_wake_result(result), do: json_wake_result(result)

  defp json_wake_result(result) do
    %{
      wake_id: result.wake_id,
      events: Enum.map(result.events, &json_monitor_event/1),
      notifications: Enum.map(result.notifications.notifications, &json_notification/1),
      notifications_saved: result.notifications.saved,
      errors: result.notifications.errors
    }
  end

  defp print_wake_trigger(trigger, json: true),
    do: print_json(%{trigger: json_wake_trigger(trigger)})

  defp print_wake_trigger(trigger, json: false) do
    IO.puts("wake trigger #{trigger.trigger_id} #{trigger.status}")

    unless trigger.name in [nil, ""] do
      IO.puts("name: #{trigger.name}")
    end

    IO.puts("schedule: #{wake_trigger_schedule_text(trigger)}")
    IO.puts("next: #{format_time(trigger.next_run_at)}")
    IO.puts("message: #{trigger.message}")

    unless trigger.last_result in [nil, ""] do
      IO.puts("last result: #{trigger.last_result}")
    end
  end

  defp print_wake_triggers(triggers, json: true) do
    print_json(%{triggers: Enum.map(triggers, &json_wake_trigger/1)})
  end

  defp print_wake_triggers(triggers, json: false) do
    IO.puts("wake triggers")

    Enum.each(triggers, fn trigger ->
      IO.puts(
        "#{trigger.trigger_id} #{trigger.status} #{wake_trigger_schedule_text(trigger)} next=#{format_time(trigger.next_run_at)} #{trigger.message}"
      )
    end)
  end

  defp print_wake_trigger_run_report(report, json: true) do
    print_json(%{
      generated_at: format_time(report.generated_at),
      total: report.total,
      notifications_saved: report.notifications_saved,
      runs: Enum.map(report.runs, &json_wake_trigger_run/1),
      errors: Enum.map(report.errors, &json_error/1)
    })
  end

  defp print_wake_trigger_run_report(report, json: false) do
    IO.puts("wake triggers due: #{report.total}")

    Enum.each(report.runs, fn run ->
      IO.puts("#{run.trigger.trigger_id}: #{run.status} #{run.result}")
    end)

    IO.puts("notifications saved: #{report.notifications_saved}")

    unless report.errors == [] do
      IO.puts(
        "errors: #{report.errors |> Enum.map(&format_error(Map.get(&1, :error))) |> Enum.join("; ")}"
      )
    end
  end

  defp wake_trigger_schedule_text(%{schedule: "every", every_seconds: every_seconds}) do
    "every #{seconds_text(every_seconds)}"
  end

  defp wake_trigger_schedule_text(_trigger), do: "once"

  defp app_version do
    case :application.get_key(:jx, :vsn) do
      {:ok, version} -> to_string(version)
      _undefined -> @version
    end
  end

  defp meet_json(%DateTime{} = value), do: format_time(value)
  defp meet_json(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp meet_json(%Date{} = value), do: Date.to_iso8601(value)
  defp meet_json(%Time{} = value), do: Time.to_iso8601(value)
  defp meet_json(values) when is_list(values), do: Enum.map(values, &meet_json/1)

  defp meet_json(%{} = map) do
    Map.new(map, fn {key, value} -> {key, meet_json(value)} end)
  end

  defp meet_json(value), do: value

  defp format_active(true), do: "yes"
  defp format_active(false), do: "no"
  defp format_active(nil), do: "-"

  defp format_bool(true), do: "yes"
  defp format_bool(false), do: "no"
  defp format_ready(true), do: "ready"
  defp format_ready(false), do: "not-ready"

  defp seconds_text(nil), do: "-"

  defp seconds_text(seconds) when is_integer(seconds) and seconds < 60,
    do: "#{seconds}s"

  defp seconds_text(seconds) when is_integer(seconds) and seconds < 3_600,
    do: "#{div(seconds, 60)}m#{rem(seconds, 60)}s"

  defp seconds_text(seconds) when is_integer(seconds) do
    hours = div(seconds, 3_600)
    minutes = seconds |> rem(3_600) |> div(60)
    "#{hours}h#{minutes}m"
  end

  defp seconds_text(value), do: to_string(value)

  defp format_attention(true), do: "yes"
  defp format_attention(false), do: "no"

  defp previous_to_current(nil, current), do: "new -> #{current}"
  defp previous_to_current(previous, current) when previous == current, do: current
  defp previous_to_current(previous, current), do: "#{previous} -> #{current}"

  defp format_counts(counts) when counts == %{}, do: ""

  defp format_counts(counts) do
    counts
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> "#{key}:#{value}" end)
    |> Enum.join(",")
  end

  defp session_queue_refs(%{items: items}) do
    items
    |> Enum.map(& &1.ref)
    |> Enum.join(",")
    |> truncate(72)
  end

  defp session_queue_focus(%{items: []}), do: ""

  defp session_queue_focus(%{items: [item | _rest]}) do
    first_present([item.task, item.current_path, item.pane])
    |> truncate(96)
  end

  defp first_present(values) do
    Enum.find_value(values, "", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end)
  end

  defp work_board_git_summary(nil), do: ""

  defp work_board_git_summary(git) do
    [
      Map.get(git, :branch, ""),
      git_divergence(git),
      if(Map.get(git, :dirty), do: "dirty:#{Map.get(git, :changes, 0)}", else: "clean"),
      if(Map.get(git, :submodules) == "error", do: "submodules:error", else: nil)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp session_dossier_repo_summary(%{present: false}), do: ""

  defp session_dossier_repo_summary(repo) do
    [
      Map.get(repo, :branch, ""),
      repo_divergence(repo),
      if(Map.get(repo, :dirty), do: "dirty:#{Map.get(repo, :changes, 0)}", else: "clean"),
      repo_flags(Map.get(repo, :blockers, []), "block"),
      repo_flags(Map.get(repo, :risks, []), "risk")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp repo_divergence(repo) do
    ahead = Map.get(repo, :ahead, 0)
    behind = Map.get(repo, :behind, 0)

    cond do
      ahead > 0 and behind > 0 -> "ahead:#{ahead}/behind:#{behind}"
      ahead > 0 -> "ahead:#{ahead}"
      behind > 0 -> "behind:#{behind}"
      true -> ""
    end
  end

  defp repo_flags([], _label), do: ""
  defp repo_flags(flags, label), do: "#{label}:#{Enum.join(flags, ",")}"

  defp git_divergence(git) do
    ahead = Map.get(git, :ahead, 0)
    behind = Map.get(git, :behind, 0)

    cond do
      ahead > 0 and behind > 0 -> "ahead:#{ahead}/behind:#{behind}"
      ahead > 0 -> "ahead:#{ahead}"
      behind > 0 -> "behind:#{behind}"
      true -> ""
    end
  end

  defp activity_command(%{process_command: command}) when command != "", do: command
  defp activity_command(%{pane_command: command}), do: command

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

  defp short_sha(nil), do: ""
  defp short_sha(value), do: value |> to_string() |> String.slice(0, 12)

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value) when is_binary(value), do: if(value == "", do: "-", else: value)

  defp blank_to_dash(value) when value in [nil, ""], do: "-"
  defp blank_to_dash(value), do: to_string(value)

  defp print_help([]), do: print_usage()

  defp print_help([group]) do
    case help_text(group) do
      {:ok, text} ->
        IO.puts(text)
        :ok

      :error ->
        {:error, "unknown help group #{inspect(group)}; available groups: #{help_groups()}"}
    end
  end

  defp print_help(_args), do: {:error, "usage: jx help [group]"}

  defp print_usage do
    IO.puts(usage_text())
    :ok
  end

  defp help_groups do
    help_group_usages()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp help_text(group) do
    group = String.downcase(group || "")

    case Map.fetch(help_group_usages(), group) do
      {:ok, lines} ->
        {:ok,
         (["jx help #{group}", ""] ++ List.wrap(lines))
         |> Enum.join("\n")}

      :error ->
        :error
    end
  end

  defp devide_usage do
    [
      "jx devide workspaces",
      "jx devide status <workspace-id>",
      "jx devide portfolio",
      "jx devide risks",
      "jx devide watch [--interval-ms N] [--state]"
    ]
  end

  defp runner_sessions_ls_usage do
    "jx sessions ls [--status created|claimed|running|progressed|completed|failed|stale|expired|ended|active|all] [--runner <id>] [--workspace <id>] [--assignment <id>] [-n 50] [--json]"
  end

  defp queue_ls_usage do
    "jx queue ls [--kind workspace|approval|action|lease|agent|runner|assignment|session] [--workspace <id>] [--owner <owner>] [--risk blocked|stale|risky|awaiting_operator] [--freshness fresh|stale|unknown] [--sort urgency|freshness|owner|risk] [--stale-after-seconds 900] [-n 50] [--json]"
  end

  defp dashboard_usage do
    "jx dashboard [--stale-after-seconds 900] [--events 25] [-n 50] [--json]"
  end

  defp dashboard_workspace_usage do
    "jx dashboard workspace <workspace-id> [--stale-after-seconds 900] [--events 25] [--json]"
  end

  defp dashboard_runner_usage do
    "jx dashboard runner <runner-id> [--events 25] [-n 100] [--json]"
  end

  defp dashboard_assignment_usage do
    "jx dashboard assignment <assignment-id> [--events 25] [-n 100] [--json]"
  end

  defp dashboard_action_usage do
    "jx dashboard action <action-id> [--events 25] [-n 100] [--json]"
  end

  defp help_group_usages do
    %{
      "approvals" => ApprovalsCLI.usage_lines(),
      "actions" => ActionsCLI.usage_lines(),
      "agents" => AgentsCLI.usage_lines(),
      "runners" => RunnersCLI.usage_lines(),
      "runtimes" => RuntimesCLI.usage_lines(),
      "assignments" => AssignmentsCLI.usage_lines(),
      "call" => [call_usage()],
      "ci" => [ci_usage()],
      "delegate" => [delegate_usage()],
      "dashboard" => [
        dashboard_usage(),
        dashboard_workspace_usage(),
        dashboard_runner_usage(),
        dashboard_assignment_usage(),
        dashboard_action_usage(),
        "",
        "Dashboard commands are read-only operational visibility. They expose event-plane projections, existing leases, assignments, runner state, replay evidence, and recovery hints without adding execution authority."
      ],
      "devide" => devide_usage(),
      "events" => [events_usage()],
      "fanout" => [FanoutCLI.usage()],
      "host" => HostCLI.usage_lines(:host),
      "hosts" => HostCLI.usage_lines(:hosts),
      "leases" => LeasesCLI.usage_lines(),
      "meet" => [meet_usage()],
      "modes" => [modes_usage()],
      "monitor" => [monitor_usage(), orchestrate_usage(), orchestrator_usage()],
      "next" => [next_usage()],
      "notifications" => [
        "jx notifications ls [--status unread|acknowledged|dismissed] [--severity info|notice|warning|critical] [--ref <ref>] [--project <name>] [-n 50] [--json]",
        "jx notifications ack <notification-id>|--all [--ref <ref>] [--project <name>] [--json]",
        "jx notifications compact [--ref <ref>] [--project <name>] [--json]"
      ],
      "orchestrator" => [orchestrator_usage(), orchestrate_usage(), monitor_usage()],
      "policy" => [
        "jx policy overview [--json]",
        "jx policy check <action> [--json]",
        "jx policy tiers [--json]"
      ],
      "portfolio" => [portfolio_summary_usage(), call_brief_usage()],
      "promote" => [promote_usage()],
      "queue" => [
        queue_ls_usage(),
        "jx queue workspace <workspace-id> [--json]",
        "jx queue rebuild [--json]"
      ],
      "project" => ProjectCLI.usage(),
      "repo" => [repo_doctor_usage(), repo_gate_usage()],
      "session" => SessionCLI.usage_lines(),
      "sessions" => [
        "jx sessions [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--action <action>] [--ssh-target <target>] [--json]",
        "jx sessions queues [--project <name>] [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--no-observe] [--lines 40] [--scan-limit 100] [-n 5] [--json]",
        "jx sessions profiles [--ref <ref>] [--project <name>] [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--next <action>] [--prompt-status none|draft|ready|sent|blocked] [--no-observe] [--lines 40] [-n 50] [--json]",
        "jx sessions reconcile [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--control managed|ignored|protected|uncontrolled] [--observe] [--lines 80] [--scan-limit 100] [--remote-limit 200] [-n 25] [--json]",
        "jx sessions recover [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--control managed|ignored|protected|uncontrolled] [--observe] [--lines 80] [--scan-limit 100] [--remote-limit 200] [-n 25] [--json]",
        runner_sessions_ls_usage(),
        "jx sessions show <session-id> [--json]",
        "jx sessions logs <session-id> [--lines 80] [--json]",
        "jx sessions attach <session-id> [--json]",
        "jx sessions expire [--json]"
      ],
      "tmux" => TmuxCLI.usage_lines(),
      "tui" => [tui_usage()],
      "wake" => [wake_usage()],
      "watch" => [watch_usage()]
    }
  end

  defp usage_text do
    """
    jx orchestrates durable SSH/tmux worktree sessions.

    Common workflows:
      jx tui
      jx tui snapshot --no-observe
      jx tui watch --interval-ms 5000
      jx tui plan
      jx call brief --observe
      jx meet session ls
      jx next
      jx portfolio summary --observe
      jx orchestrator status
      jx modes
      jx sessions queues --managed
      jx ci watches --status active
      jx delegate reviews
      jx fanout plan test-coverage --baseline 53907e03
      jx fanout preflight test-coverage-2026-05-08
      jx fanout launch test-coverage-2026-05-08 --all
      jx fanout monitor test-coverage-2026-05-08
      jx fanout status test-coverage-2026-05-08
      jx queue ls --sort urgency
      jx promote preflight example-project --from develop --to master
      jx promote run example-project --from develop --to master
      jx leases ls --status active
      jx agents ls
      jx runners ls
      jx runtimes ls
      jx assignments ls --status active
      jx dashboard
      jx sessions ls --status active
      jx devide portfolio
      jx approvals ls
      jx help ci
      jx help sessions

    Usage:
      jx [--db path] help [group]
      jx [--db path] modes [<mode>|playbook <mode>] [--json]
      jx [--db path] next [--host <host>] [--project <name>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--no-observe] [--lines 80] [--scan-limit 100] [-n 5] [--json]
      jx [--db path] wake --message <text> [--project <name>] [--ref <ref>] [--severity info|notice|warning|critical] [--json]
      jx [--db path] wake add --message <text> (--at <iso8601>|--in <duration>|--every <duration>) [--name <name>] [--project <name>] [--ref <ref>] [--severity info|notice|warning|critical] [--json]
      jx [--db path] wake ls [--status active|disabled|completed|cancelled] [--project <name>] [--ref <ref>] [-n 50] [--json]
      jx [--db path] wake run-due [--limit 20] [--json]
      jx [--db path] wake remove <trigger-id> [--json]
      jx [--db path] tui [--consumer <name>] [--project <name>] [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--no-observe] [--lines 80] [--scan-limit 100] [--stale-after-seconds 120] [-n 5] [--no-clear]
      jx [--db path] tui snapshot [same filters] [--json]
      jx [--db path] tui watch [same filters] [--interval-ms 5000] [--iterations <n>] [--no-clear]
      jx [--db path] tui interactive [same filters]
      jx [--db path] tui plan [--json]
      jx [--db path] init
      jx [--db path] host add <name> (--ssh <user@host> | --local) --workspace <path>
      jx [--db path] host ls
      jx [--db path] host doctor <host> [--agent claude|opencode|codex] [--transport native|acpx]
      jx [--db path] hosts doctor [--agent claude|opencode|codex] [--transport native|acpx] [--json]
      jx [--db path] project add <name> --host <host> --repo <path>
      jx [--db path] project gate <name> [--json]
      jx [--db path] promote preflight <project> --from <source-branch> --to <target-branch> [--json]
      jx [--db path] promote run <project> --from <source-branch> --to <target-branch> [--json]
      jx [--db path] repo doctor <name> [--host <host>] [--base <branch>] [--promote-to <branch>] [--json]
      jx [--db path] repo gate <name> [--host <host>] [--base <branch>] [--promote-to <branch>] [--json]
      jx [--db path] project brief <name> [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--no-observe] [--lines 80] [--scan-limit 100] [-n 5] [--json]
      jx [--db path] project ls [--json]
      jx [--db path] ci digest <pr-number> --repo <owner/repo> [--no-logs] [--json]
      jx [--db path] fanout plan <plan-id> --baseline <sha> [--base-branch <branch>] [--coverage-file <path> --host-count <n> --risk-rules <json-or-path>] [--host <name[=base,worktree_root,validation_prefix]>] [--root <dir>] [--run-id <id>] [--json]
      jx [--db path] fanout preflight <run-id-or-path> [--root <dir>] [--ttl-seconds <n>] [--json]
      jx [--db path] fanout launch <run-id-or-path> [assignment-id|--all] [--root <dir>] [--lease-timeout-seconds <n>] [--codex-bin <path>] [--tmux-server <name>] [--json]
      jx [--db path] fanout monitor <run-id-or-path> [--root <dir>] [--json]
      jx [--db path] fanout ownership <run-id-or-path> <assignment-id> [--root <dir>] [--warn-only] [--json]
      jx [--db path] fanout pr <run-id-or-path> <assignment-id> [--root <dir>] [--repo <owner/repo>] [--register-ci-watch] [--ci-watch-mode notify|hold|prompt] [--allow-unvalidated] [--json]
      jx [--db path] fanout status <run-id-or-path> [--root <dir>] [--json]
      jx [--db path] devide workspaces
      jx [--db path] devide status <workspace-id>
      jx [--db path] devide portfolio
      jx [--db path] devide risks
      jx [--db path] devide watch [--interval-ms N] [--state]
      jx [--db path] approvals ls [--status open|acknowledged|dismissed|active|all] [--source devide] [--workspace <id>] [--kind proposal_conflict|unsafe_db|failed_run|policy_blocked] [-n 50] [--json]
      jx [--db path] approvals show <id> [--json]
      jx [--db path] approvals ack <id> [--json]
      jx [--db path] approvals dismiss <id> [--json]
      jx [--db path] queue ls [--kind workspace|approval|action|lease|agent|runner|assignment|session] [--workspace <id>] [--owner <owner>] [--risk blocked|stale|risky|awaiting_operator] [--freshness fresh|stale|unknown] [--sort urgency|freshness|owner|risk] [--stale-after-seconds 900] [-n 50] [--json]
      jx [--db path] queue workspace <workspace-id> [--json]
      jx [--db path] dashboard [--stale-after-seconds 900] [--events 25] [-n 50] [--json]
      jx [--db path] dashboard workspace <workspace-id> [--stale-after-seconds 900] [--events 25] [--json]
      jx [--db path] dashboard runner <runner-id> [--events 25] [-n 100] [--json]
      jx [--db path] dashboard assignment <assignment-id> [--events 25] [-n 100] [--json]
      jx [--db path] dashboard action <action-id> [--events 25] [-n 100] [--json]
      jx [--db path] leases ls [--owner <owner>] [--status active|released|expired|reassigned|all] [--resource approval:<id>|action:<id>|workspace:<id>] [--stale] [-n 50] [--json]
      jx [--db path] leases acquire approval|action|workspace <id> --owner <owner> [--ttl-seconds 900] [--json]
      jx [--db path] leases release <lease-id> --owner <owner> [--json]
      jx [--db path] leases reassign approval|action|workspace <id> --owner <owner> [--ttl-seconds 900] [--json]
      jx [--db path] agents register <agent-id> [--name <name>] [--capability <cap>] [--workspace <id>] [--ttl-seconds 120] [--json]
      jx [--db path] agents heartbeat <agent-id> [--json]
      jx [--db path] agents ls [--status idle|busy|stale|disabled|all] [-n 50] [--json]
      jx [--db path] runners register <runner-id> [--agent <agent-id>] [--host <host>] [--capability <cap>] [--workspace <id>] [--ttl-seconds 120] [--tmux-server <server>] [--tmux-session-prefix <prefix>] [--json]
      jx [--db path] runners heartbeat <runner-id> [--session <id>] [--json]
      jx [--db path] runners ls [--status idle|busy|stale|disabled|all] [-n 50] [--json]
      jx [--db path] runners show <runner-id> [--json]
      jx [--db path] runtimes ls [--status planned|provisioning|ready|assigned|released|failed|expired|active|all] [--workspace <id>] [--runner <id>] [-n 50] [--json]
      jx [--db path] runtimes provision <action-id> --project <project> [--host <host>] [--runner <runner-id>] [--tool <tool>] [--capability <cap>] [--os <os>] [--branch-isolation worktree] [--concurrency-limit 1] [--ttl-seconds 86400] [--json]
      jx [--db path] runtimes assign <runtime-id> <action-id> [--runner <runner-id>] [--session <session-id>] [--ttl-seconds 86400] [--json]
      jx [--db path] runtimes show <runtime-id> [--json]
      jx [--db path] runtimes release <runtime-id> [--json]
      jx [--db path] assignments create <action-id> [--created-by <operator>] [--ttl-seconds 1800] [--json]
      jx [--db path] assignments ls [--status created|claimed|started|progressed|completed|failed|expired|active|all] [--agent <id>] [--workspace <id>] [-n 50] [--json]
      jx [--db path] assignments claim <assignment-id> (--agent <agent-id>|--runner <runner-id>) [--session <id>] [--tmux-session <name>] [--log-path <path>] [--json]
      jx [--db path] assignments start <assignment-id> --agent <agent-id> [--json]
      jx [--db path] assignments progress <assignment-id> --agent <agent-id> --summary <text> [--json]
      jx [--db path] assignments execute <assignment-id> --agent <agent-id> --confirm [--json]
      jx [--db path] assignments fail <assignment-id> --agent <agent-id> --summary <text> [--json]
      jx [--db path] assignments expire [--json]
      jx [--db path] sessions ls [--status created|claimed|running|progressed|completed|failed|stale|expired|ended|active|all] [--runner <id>] [--workspace <id>] [--assignment <id>] [-n 50] [--json]
      jx [--db path] sessions show <session-id> [--json]
      jx [--db path] sessions logs <session-id> [--lines 80] [--json]
      jx [--db path] sessions attach <session-id> [--json]
      jx [--db path] sessions expire [--json]
      jx [--db path] timeline workspace|approval|action|assignment|agent|runner|session <id> [-n 100] [--json]
      jx [--db path] portfolio summary [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--no-observe] [--lines 80] [--scan-limit 100] [-n 25] [--json]
      jx [--db path] call brief [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--observe] [--lines 80] [--scan-limit 100] [-n 5] [--json]
      jx [--db path] call handoff add --summary <text> [--title <text>] [--surface call|phone|meet|talk|chat] [--project <name>] [--ref <ref>] [--operator-input <text>] [--decision <text>] [--follow-up <text>] [--no-brief] [--json]
      jx [--db path] call handoff ls [--status open|applied|closed] [--surface call|phone|meet|talk|chat] [--project <name>] [--ref <ref>] [-n 20] [--json]
      jx [--db path] call handoff apply <handoff-id> [--action prompt|watch|hold ...] [--summary <text>] [--json]
      jx [--db path] call handoff close <handoff-id> [--summary <text>] [--json]
      jx [--db path] meet plugin [--json]
      jx [--db path] meet auth configure --client-id <id> [--profile personal] [--email <email>] [--client-secret-env <env>] [--redirect-uri <uri>] [--scope <scope>] [--artifacts] [--json]
      jx [--db path] meet auth url [--profile personal] [--login-hint <email>] [--scope <scope>] [--json]
      jx [--db path] meet auth exchange --code <code> [--profile personal] [--json]
      jx [--db path] meet auth status [--profile personal] [-n 50] [--json]
      jx [--db path] meet session create --meeting <meet-url-or-code> [--title <text>] [--project <name>] [--ref <ref>] [--auth-profile personal] [--chrome-node <debug-url>] [--paired-chrome-node <debug-url>] [--twilio-stream-url <wss-url>] [--twilio-mode none|start|connect] [--twilio-track inbound_track|outbound_track|both_tracks] [--artifact-dir <path>] [--no-handoff] [--json]
      jx [--db path] meet session ls [--status planned|joining|live|recovered|ended|failed] [--project <name>] [--ref <ref>] [--meeting <meet-url-or-code>] [-n 50] [--json]
      jx [--db path] meet session plan <session-id> [--json]
      jx [--db path] meet session join <session-id> [--runner browser-agent|chrome-cdp] [--browser-agent-command <cmd>] [--debug-url <url>] [--launch] [--no-click] [--no-mute] [--no-camera-off] [--json]
      jx [--db path] meet realtime plan <session-id> [--provider browser-agent|openai-realtime|gemini-live] [--audio-bridge browser-agent|twilio|command] [--browser-agent-command <cmd>] [--json]
      jx [--db path] meet realtime start <session-id> [--provider browser-agent|openai-realtime|gemini-live] [--audio-bridge browser-agent|twilio|command] [--browser-agent-command <cmd>] [--live] [--approve-audio-capture] [--approve-speech-output] [--approve-notes-or-transcription] [--json]
      jx [--db path] meet realtime watch <session-id> [--browser-agent-command <cmd> | --caption-file <path> | --chat-file <path>] [--iterations <n>] [--interval-ms <ms>] [--speak] [--speech-output-command <cmd>] [--json]
      jx [--db path] meet realtime consult <session-id> --transcript <text> [--summary <text>] [--decision <text>] [--follow-up <text>] [--json]
      jx [--db path] meet recover (--debug-url <url> | --targets-json <path>) [--paired-debug-url <url> | --paired-targets-json <path>] [--meeting <meet-url-or-code>] [--project <name>] [--ref <ref>] [--dry-run] [--no-handoff] [--json]
      jx [--db path] meet sync <session-id> [--json]
      jx [--db path] meet export <session-id> [--dir <path>] [--format all|json|markdown|attendance-csv|twiml] [--json]
      jx [--db path] assign <project> "<task prompt>" [--host <host>] [--agent claude|opencode|codex] [--transport native|acpx] [--goal] [--goal-objective <objective>]
      jx [--db path] operate [--observe] [--execute safe|rec-id] [--yes] [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--target <ssh-target>] [--lines 40] [--stale-seconds 300] [-n 20] [--json]
      jx [--db path] manage [--policy conservative] [--iterations 1] [--sleep-ms 0] [--host <host>] [--type agent|process|ssh|task|tmux] [--json]
      jx [--db path] orchestrator start|status|stop|logs|health|heartbeats|inbox [--dry-run] [--session #{OrchestratorDaemon.default_session_name()}] [--server #{Tmux.managed_server()}] [--log <path>] [--json]
      jx [--db path] orchestrate step|run|start [--consumer orchestrator] [--execute] [--yes] [--ack|--no-ack] [--auto-plan] [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--prompt-status none|draft|ready|sent|blocked] [--no-observe] [--lines 40] [--scan-limit 100] [--queue-limit 5] [--event-limit 50] [--decision-limit 20] [--min-observe-age-seconds 30] [--interval-ms 30000] [--iterations 0] [--no-enter] [--json]
      jx [--db path] sessions recover [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--control managed|ignored|protected|uncontrolled] [--observe] [--lines 80] [--scan-limit 100] [--remote-limit 200] [-n 25] [--json]
      jx [--db path] monitor scan|run|start [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--prompt-status none|draft|ready|sent|blocked] [--no-observe] [--lines 40] [--scan-limit 100] [--queue-limit 5] [--event-limit 20] [--interval-ms 30000] [--iterations 0] [--json]
      jx [--db path] monitor status [--consumer <name>] [--json]
      jx [--db path] events check [-n 10000] [--json]
      jx [--db path] events ls [--since <id>] [--ref <ref>] [--kind <kind>] [--severity info|notice|warning|critical] [-n 20] [--json]
      jx [--db path] events unread [--consumer <name>] [--ref <ref>] [--kind <kind>] [--severity info|notice|warning|critical] [-n 20] [--json]
      jx [--db path] events ack [--consumer <name>] (--to <id> | --latest) [--json]
      jx [--db path] events cursor [--consumer <name>] [--json]
      jx [--db path] work [ls] [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--lines 40] [-n 50] [--json]
      jx [--db path] operations ls [--ref <ref>] [--action <action>] [--status executed|skipped|error] [-n 20] [--json]
      jx [--db path] actions ls [--source <source>] [--ref <ref>] [--action <action>] [--status planned|queued|executed|skipped|error|cancelled] [-n 50] [--json]
      jx [--db path] actions show <action-id> [--json]
      jx [--db path] actions history <approval-id> [--json]
      jx [--db path] actions propose <approval-id> [--kind rerun_devide_command|acknowledge_approval] [--owner <owner>] [--json]
      jx [--db path] actions dry-run <action-id> [--owner <owner>] [--json]
      jx [--db path] actions execute <action-id> --confirm [--owner <owner>] [--json]
      jx [--db path] notifications ls [--status unread|acknowledged|dismissed] [--severity info|notice|warning|critical] [--ref <ref>] [--project <name>] [-n 50] [--json]
      jx [--db path] notifications ack <notification-id>|--all [--ref <ref>] [--project <name>] [--json]
      jx [--db path] notifications compact [--ref <ref>] [--project <name>] [--json]
      jx [--db path] policy overview [--json]
      jx [--db path] policy check <action> [--json]
      jx [--db path] policy tiers [--json]
      jx [--db path] controls ls [--mode managed|ignored|protected] [-n 50] [--json]
      jx [--db path] watch add <ref> --goal <text> (--success <pattern> | --blocker <pattern>) [--mode notify|hold|prompt] [--prompt <text>] [--json]
      jx [--db path] watch ls [--status active|completed|blocked|cancelled] [--ref <ref>] [-n 50] [--json]
      jx [--db path] watch review <watch-id> [--no-observe] [--lines 160] [--all-processes] [--json]
      jx [--db path] watch complete <watch-id> [--summary <text>] [--json]
      jx [--db path] watch cancel <watch-id> [--summary <text>] [--json]
      jx [--db path] remote ls [--target <ssh-target>] [--ref <ref>] [-n 50] [--json]
      jx [--db path] discover [--host <host>] [--managed]
      jx [--db path] activity [--host <host>] [--managed] [--all-processes]
      jx [--db path] sessions [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--action <action>] [--ssh-target <target>] [--json]
      jx [--db path] sessions snapshot [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--action <action>] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [-n 40] [--save] [--json] [--compact]
      jx [--db path] sessions summary [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--target <ssh-target>] [--observe] [--lines 40] [--stale-seconds 300] [-n 20] [--json]
      jx [--db path] sessions observe [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--action <action>] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--attention] [-n 40] [--json]
      jx [--db path] sessions changed [--since <id>] [--ref <ref>] [--severity info|notice|warning|critical] [-n 20] [--json]
      jx [--db path] sessions ready [--project <name>] [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--control managed|ignored|protected|uncontrolled] [--no-observe] [--lines 40] [-n 20] [--json]
      jx [--db path] sessions queues [--project <name>] [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--no-observe] [--lines 40] [--scan-limit 100] [-n 5] [--json]
      jx [--db path] sessions dossiers [--ref <ref>] [--project <name>] [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--next <action>] [--no-observe] [--lines 40] [-n 50] [--json]
      jx [--db path] sessions profiles [--ref <ref>] [--project <name>] [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--next <action>] [--prompt-status none|draft|ready|sent|blocked] [--no-observe] [--lines 40] [-n 50] [--json]
      jx [--db path] sessions reconcile [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--control managed|ignored|protected|uncontrolled] [--observe] [--lines 80] [--scan-limit 100] [--remote-limit 200] [-n 25] [--json]
      jx [--db path] sessions history [--ref <ref>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [-n 20] [--json]
      jx [--db path] sessions changes [--ref <ref>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--attention] [-n 20] [--json]
      jx [--db path] sessions stale [--ref <ref>] [--host <host>] [--type agent|process|ssh|task|tmux] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--seconds 300] [-n 20] [--json]
      jx [--db path] sessions broadcast "<message>" [--host <host>] [--type agent|process|ssh|task|tmux] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--attention] [-n 40] [--yes] [--no-enter] [--json]
      jx [--db path] sessions remote [--target <ssh-target>] [--probe] [--force] [--timeout-ms 5000] [--json]
      jx [--db path] directives ls [--host <host>] [--task <task-id>] [-n 20]
      jx [--db path] ssh ls
      jx [--db path] ssh probe [--target <target>]
      jx ssh pane-probe --all [--target <ssh-target>] [--dry-run] [--timeout-ms 5000]
      jx ssh pane-probe --session <name> [--server <server>] [--window 0] [--pane 0] [--timeout-ms 5000]
      jx [--db path] tmux ls <host> [--all] [--server <server>]
      jx [--db path] tmux panes <host> [--all] [--server <server>]
      jx [--db path] tmux capture <host> <session> [--server <server>] [--window 0] [--pane 0] [-n 80]
      jx [--db path] tmux send <host> <session> "<message>" [--server <server>] [--window 0] [--pane 0] [--no-enter]
      jx [--db path] tmux attach <host> <session> [--server <server>]
      jx [--db path] tmux stop <host> <session> [--server <server>]
      jx process ls [--kind codex|claude|opencode|ssh|sshd|tmux] [--all]
      jx [--db path] operator profile [--json]
      jx [--db path] operator profile set [--name <name>] [--preferences <text>] [--style <text>] [--escalation <text>] [--notes <text>] [--json]
      jx [--db path] task adopt-tmux <project> --session <name> --worktree <path> [--server <server>] [--window 0] [--pane 0] [--agent claude|opencode|codex]
      jx [--db path] task adopt-activity <project> --server <server> --session <name> [--window 0] [--pane 0] [--agent claude|opencode|codex]
      jx [--db path] task send <task-id> "<message>" [--window 0] [--pane 0] [--no-enter]
      jx [--db path] session capture <ref> [-n 80]
      jx [--db path] session attach <ref>
      jx [--db path] session inspect <ref> [--json]
      jx [--db path] session profile <ref> [--summary <text>] [--objective <text>] [--expect <text>] [--next-prompt <text>] [--prompt-status none|draft|ready|sent|blocked] [--strategy <text>] [--notes <text>] [--owner <name>] [--risk low|normal|high|blocked] [--lifecycle active|parked|done|blocked] [--hypothesis <text>] [--evidence <text>] [--stale-after <seconds>] [--no-observe] [--lines 40] [--json]
      jx [--db path] session mark <ref> --mode managed|ignored|protected [--project <name>] [--note <text>]
      jx [--db path] session unmark <ref>
      jx [--db path] session send <ref> "<message>" [--no-enter]
      jx [--db path] session key <ref> "<keys>" [--no-enter] [--json]
      jx [--db path] session probe <ref> [--force] [--timeout-ms 5000] [--json]
      jx [--db path] session resume-adopt <ref> <project> [--agent claude|opencode|codex] [--relaunch] [--json]
      jx [--db path] session stream-adopt <ref> <project> [--agent claude|opencode|codex] [--transport native|acpx] [--relaunch] [--json]
      jx [--db path] session adopt <ref> <project> [--agent claude|opencode|codex]
      jx [--db path] status
      jx [--db path] attach <task-id>
      jx [--db path] logs <task-id> [-n 200] [-f]
      jx [--db path] stop <task-id>
    """
  end

  defp format_error({:host_not_found, host}), do: "host not found: #{host}"
  defp format_error(:host_not_found), do: "host not found"
  defp format_error(:project_not_found), do: "project not found"

  defp format_error({:project_not_found, project_name, host_name}),
    do: "project #{project_name} not found on host #{host_name}"

  defp format_error(:task_not_found), do: "task not found"
  defp format_error(:session_not_found), do: "session not found"
  defp format_error(:watch_not_found), do: "watch not found"
  defp format_error(:wake_trigger_not_found), do: "wake trigger not found"
  defp format_error(:notification_not_found), do: "notification not found"
  defp format_error(:approval_not_found), do: "approval not found"
  defp format_error({:action_not_found, action_id}), do: "action not found: #{action_id}"

  defp format_error({:approval_not_found, approval_id}),
    do: "approval not found: #{approval_id}"

  defp format_error({:action_already_executed, action_id}),
    do: "action already executed: #{action_id}"

  defp format_error({:action_expired, action_id}), do: "action expired: #{action_id}"

  defp format_error({:action_revoked, action_id}), do: "action revoked: #{action_id}"

  defp format_error({:action_not_executable, status}),
    do: "action cannot execute from status: #{status}"

  defp format_error({:approval_mismatch, action_id}),
    do: "action approval evidence no longer matches approval: #{action_id}"

  defp format_error({:lease_conflict, lease}),
    do:
      "lease conflict: #{lease.resource_type}:#{lease.resource_id} is claimed by #{lease.owner} until #{format_time(lease.expires_at)}"

  defp format_error(:lease_not_found), do: "lease not found"

  defp format_error({:lease_not_active, status}),
    do: "lease is not active: #{status}"

  defp format_error({:lease_owner_mismatch, owner}),
    do: "lease is owned by #{owner}"

  defp format_error({:unsupported_lease_resource, resource}),
    do: "unsupported lease resource: #{resource}"

  defp format_error({:missing_required, field}), do: "#{field} is required"

  defp format_error({:invalid_ttl_seconds, ttl}),
    do: "ttl seconds must be a positive integer, got #{inspect(ttl)}"

  defp format_error(:agent_not_found), do: "agent not found"
  defp format_error(:assignment_or_agent_not_found), do: "assignment or agent not found"

  defp format_error({:agent_stale, agent_id}), do: "agent #{agent_id} is stale"

  defp format_error({:agent_missing_capabilities, capabilities}),
    do: "agent is missing required capabilities: #{Enum.join(capabilities, ",")}"

  defp format_error({:agent_workspace_mismatch, workspace_id}),
    do: "agent is not affiliated with workspace #{workspace_id}"

  defp format_error(:runner_not_found), do: "runner not found"
  defp format_error(:runner_session_not_found), do: "runner session not found"
  defp format_error(:assignment_or_runner_not_found), do: "assignment or runner not found"
  defp format_error(:runner_session_or_runner_not_found), do: "runner session or runner not found"

  defp format_error({:runner_stale, runner_id}), do: "runner #{runner_id} is stale"

  defp format_error({:runner_missing_capabilities, capabilities}),
    do: "runner is missing required capabilities: #{Enum.join(capabilities, ",")}"

  defp format_error({:runner_workspace_mismatch, workspace_id}),
    do: "runner is not affiliated with workspace #{workspace_id}"

  defp format_error({:runner_session_conflict, session}),
    do:
      "assignment already has active runner session #{session.session_id} owned by #{session.runner_id}"

  defp format_error({:runner_session_owned_by, runner_id}),
    do: "runner session is owned by #{runner_id}"

  defp format_error({:runner_session_closed, status}),
    do: "runner session is closed: #{status}"

  defp format_error({:assignment_closed, status}), do: "assignment is closed: #{status}"

  defp format_error({:assignment_claimed_by, agent_id}),
    do: "assignment is claimed by #{blank_to_dash(agent_id)}"

  defp format_error({:assignment_not_executable, status}),
    do: "assignment cannot execute from status: #{status}"

  defp format_error({:action_not_assignable, status}),
    do: "safe action cannot be assigned from status: #{status}"

  defp format_error({:unsupported_safe_action_source, source}),
    do: "safe action source #{source} is not delegatable"

  defp format_error({:workspace_snapshot_not_found, workspace_id}),
    do: "DevIDE workspace snapshot not found: #{workspace_id}"

  defp format_error({:approval_not_active, status}),
    do: "approval is not active: #{status}"

  defp format_error({:approval_not_open, status}),
    do: "approval is not open: #{status}"

  defp format_error({:unsupported_approval_source, source}),
    do: "approval source #{source} does not support this safe action"

  defp format_error({:unsupported_approval_kind, kind}),
    do: "approval kind #{kind} does not map to a deterministic safe action"

  defp format_error({:unsafe_db_isolation, isolation}),
    do: "DevIDE workspace DB isolation is unsafe for action proposal: #{isolation}"

  defp format_error({:unsupported_db_isolation, isolation}),
    do: "DevIDE workspace DB isolation is not allowlisted for action proposal: #{isolation}"

  defp format_error({:unsupported_devide_command, command, allowed}) do
    "DevIDE command #{inspect(command)} is not allowlisted; expected one of: #{Enum.join(allowed, ", ")}"
  end

  defp format_error({:unsupported_safe_action, action}),
    do: "unsupported safe action: #{action}"

  defp format_error({:workspace_mismatch, approval_workspace, snapshot_workspace}),
    do:
      "approval workspace #{approval_workspace} does not match snapshot workspace #{snapshot_workspace}"

  defp format_error(:confirmation_required), do: "confirmation required; pass --confirm"

  defp format_error(%JX.DevIDE.Client.Error{} = error), do: JX.DevIDE.Client.format_error(error)

  defp format_error(:google_meet_auth_profile_not_found), do: "Google Meet auth profile not found"
  defp format_error(:google_meet_session_not_found), do: "Google Meet session not found"
  defp format_error(:session_not_tmux), do: "session is not backed by a tmux pane"
  defp format_error(:session_not_ssh), do: "session is not an SSH-backed tmux pane"

  defp format_error({:session_not_stream_adoptable, ref}),
    do: "session #{ref} is not stream-adoptable"

  defp format_error({:session_not_resume_adoptable, ref}),
    do: "session #{ref} is not resume-adoptable"

  defp format_error({:unsupported_agent_transport, agent_transport}),
    do:
      "unsupported agent transport #{inspect(agent_transport)}; expected one of: #{Enum.join(AgentRunner.agent_transports(), ", ")}"

  defp format_error({:unsupported_goal_agent, agent_name}),
    do: "Codex goals require --agent codex; got #{inspect(agent_name)}"

  defp format_error({:unsupported_goal_transport, agent_transport}),
    do: "Codex goals require --transport native; got #{inspect(agent_transport)}"

  defp format_error({:project_host_mismatch, project, project_host, session_host}),
    do:
      "project #{project} is registered on host #{project_host}, but session is on host #{session_host}"

  defp format_error(:resume_not_found), do: "resume context not found"

  defp format_error({:directive_policy_denied, reason}), do: "directive denied: #{reason}"

  defp format_error({:session_probe_requires_force, ref}),
    do:
      "session #{ref} appears active; capture it first, then rerun probe with --force if intentional"

  defp format_error({:session_probe_needs_shell_prompt, ref}),
    do:
      "session #{ref} appears to be an agent UI; remote probe needs direct SSH auth or a shell prompt"

  defp format_error(:pane_not_found), do: "tmux pane not found"
  defp format_error(:pane_worktree_unknown), do: "tmux pane current path is empty"
  defp format_error(:runtime_not_found), do: "runtime environment not found"
  defp format_error(:project_required), do: "project is required"
  defp format_error({:runtime_not_ready, status}), do: "runtime is not ready: #{status}"

  defp format_error({:provision_failed, reason, _runtime}),
    do: "runtime provisioning failed: #{inspect(reason)}"

  defp format_error(:remote_probe_requires_force), do: "remote probe requires --force"
  defp format_error(:remote_probe_needs_shell_prompt), do: "remote probe needs a shell prompt"
  defp format_error({:ssh_failed, status, output}), do: "ssh failed with #{status}: #{output}"

  defp format_error({:unsupported_agent, agent}),
    do:
      "unsupported agent #{inspect(agent)}; expected one of: #{Enum.join(AgentRunner.agent_names(), ", ")}"

  defp format_error({:local_failed, status, output}),
    do: "local command failed with #{status}: #{output}"

  defp format_error({:process_inventory_failed, status, output}),
    do: "process inventory failed with #{status}: #{output}"

  defp format_error({:tmux_inventory_failed, status, output}),
    do: "tmux inventory failed with #{status}: #{output}"

  defp format_error({:pane_transport_failed, step, status, output}),
    do: "tmux pane #{step} failed with #{status}: #{output}"

  defp format_error({:orchestrator_already_running, status}),
    do: "orchestrator already running in #{status.tmux_server}/#{status.session_name}"

  defp format_error({:orchestrator_tmux_failed, status, output}),
    do: "orchestrator tmux command failed with #{status}: #{output}"

  defp format_error({:orchestrator_log_failed, reason, path}),
    do: "orchestrator log read failed for #{path}: #{inspect(reason)}"

  defp format_error({:invalid_orchestrator_session, session}),
    do: "invalid orchestrator session name: #{inspect(session)}"

  defp format_error({:invalid_tmux_server, server}),
    do: "invalid tmux server: #{inspect(server)}"

  defp format_error({:pane_probe_timeout, target, timeout_ms}),
    do: "pane probe timed out after #{timeout_ms}ms waiting for #{target}"

  defp format_error({:attach_failed, status}), do: "attach failed with #{status}"
  defp format_error({:logs_failed, status}), do: "logs failed with #{status}"

  defp format_error({:application_start_failed, app, reason}),
    do: "failed to start #{inspect(app)}: #{inspect(reason)}"

  defp format_error({:invalid_evidence, reason}), do: reason

  defp format_error({:delegation_not_completed, status}),
    do: "delegation is not completed: #{status}"

  defp format_error({:delegation_conflict, %{conflicts: conflicts}}) do
    conflicts =
      conflicts
      |> Enum.map(fn conflict ->
        "#{conflict.path} overlaps #{conflict.conflicting_path} in #{conflict.delegation_id}"
      end)
      |> Enum.join("; ")

    "delegation write ownership conflict: #{conflicts}"
  end

  defp format_error({reason, _task}), do: format_error(reason)
  defp format_error(%Ecto.Changeset{} = changeset), do: inspect(changeset.errors)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
