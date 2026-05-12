defmodule JX.CLI.Sessions do
  @moduledoc false

  alias JX.MonitorEvents
  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @sessions_usage "jx sessions [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--action <action>] [--ssh-target <target>] [--json]"
  @snapshot_usage "jx sessions snapshot [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--action <action>] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [-n 40] [--save] [--json] [--compact]"
  @summary_usage "jx sessions summary [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--target <ssh-target>] [--observe] [--lines 40] [--stale-seconds 300] [-n 20] [--json]"
  @observe_usage "jx sessions observe [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--action <action>] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--attention] [-n 40] [--json]"
  @changed_usage "jx sessions changed [--since <id>] [--ref <ref>] [--severity info|notice|warning|critical] [-n 20] [--json]"
  @ready_usage "jx sessions ready [--project <name>] [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--control managed|ignored|protected|uncontrolled] [--no-observe] [--lines 40] [-n 20] [--json]"
  @queues_usage "jx sessions queues [--project <name>] [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--no-observe] [--lines 40] [--scan-limit 100] [-n 5] [--json]"
  @dossiers_usage "jx sessions dossiers [--ref <ref>] [--project <name>] [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--next <action>] [--no-observe] [--lines 40] [-n 50] [--json]"
  @profiles_usage "jx sessions profiles [--ref <ref>] [--project <name>] [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--control managed|ignored|protected|uncontrolled] [--next <action>] [--prompt-status none|draft|ready|sent|blocked] [--no-observe] [--lines 40] [-n 50] [--json]"
  @reconcile_usage "jx sessions reconcile [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--control managed|ignored|protected|uncontrolled] [--observe] [--lines 80] [--scan-limit 100] [--remote-limit 200] [-n 25] [--json]"
  @recover_usage "jx sessions recover [--host <host>] [--managed] [--all-processes] [--type agent|process|ssh|task|tmux] [--ssh-target <target>] [--control managed|ignored|protected|uncontrolled] [--observe] [--lines 80] [--scan-limit 100] [--remote-limit 200] [-n 25] [--json]"
  @history_usage "jx sessions history [--ref <ref>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [-n 20] [--json]"
  @changes_usage "jx sessions changes [--ref <ref>] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--attention] [-n 20] [--json]"
  @stale_usage "jx sessions stale [--ref <ref>] [--host <host>] [--type agent|process|ssh|task|tmux] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--seconds 300] [-n 20] [--json]"
  @broadcast_usage "jx sessions broadcast \"<message>\" [--host <host>] [--type agent|process|ssh|task|tmux] [--work-state unobservable|unknown|blocked|running|waiting|idle] [--attention] [-n 40] [--yes] [--no-enter] [--json]"
  @remote_usage "jx sessions remote [--target <ssh-target>] [--probe] [--force] [--timeout-ms 5000] [--json]"
  @runner_sessions_ls_usage "jx sessions ls [--status created|claimed|running|progressed|completed|failed|stale|expired|ended|active|all] [--runner <id>] [--workspace <id>] [--assignment <id>] [-n 50] [--json]"
  @runner_session_show_usage "jx sessions show <session-id> [--json]"
  @runner_session_logs_usage "jx sessions logs <session-id> [--lines 80] [--json]"
  @runner_session_attach_usage "jx sessions attach <session-id> [--json]"
  @runner_session_expire_usage "jx sessions expire [--json]"

  def usage_lines do
    [
      @sessions_usage,
      @snapshot_usage,
      @summary_usage,
      @observe_usage,
      @changed_usage,
      @ready_usage,
      @queues_usage,
      @dossiers_usage,
      @profiles_usage,
      @reconcile_usage,
      @recover_usage,
      @history_usage,
      @changes_usage,
      @stale_usage,
      @broadcast_usage,
      @remote_usage,
      @runner_sessions_ls_usage,
      @runner_session_show_usage,
      @runner_session_logs_usage,
      @runner_session_attach_usage,
      @runner_session_expire_usage
    ]
  end

  def usage, do: Enum.join(usage_lines(), " | ")

  def run(["snapshot" | args], opts) do
    {parsed, rest, invalid} =
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

    lines = parsed[:n] || 40

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @snapshot_usage),
         :ok <- validate_optional_session_type(parsed[:type]),
         :ok <- validate_optional_work_state(parsed[:work_state]),
         :ok <- validate_positive("n", lines),
         :ok <- start_app(opts),
         {:ok, report} <-
           apply(workspace(opts), :snapshot_sessions, [
             [
               host_name: parsed[:host],
               all_tmux: !parsed[:managed],
               all_processes: parsed[:all_processes] || false,
               type: parsed[:type],
               action: parsed[:action],
               ssh_target: parsed[:ssh_target],
               work_state: parsed[:work_state],
               lines: lines
             ]
           ]),
         {:ok, saved_count} <- maybe_save_snapshot(opts, report, parsed[:save] || false) do
      print_sessions_snapshot(report,
        json: parsed[:json] || false,
        compact: parsed[:compact] || false,
        saved: saved_count
      )

      :ok
    end
  end

  def run(["summary" | args], opts) do
    {parsed, rest, invalid} =
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

    limit = parsed[:n] || 20
    lines = parsed[:lines] || 40
    stale_after_seconds = parsed[:stale_seconds] || 300

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @summary_usage),
         :ok <- validate_optional_session_type(parsed[:type]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("stale-seconds", stale_after_seconds),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts),
         {:ok, summary} <-
           apply(workspace(opts), :session_summary, [
             [
               host_name: parsed[:host],
               all_tmux: !parsed[:managed],
               all_processes: parsed[:all_processes] || false,
               type: parsed[:type],
               ssh_target: parsed[:ssh_target],
               target: parsed[:target],
               observe: parsed[:observe] || false,
               lines: lines,
               stale_after_seconds: stale_after_seconds,
               limit: limit
             ]
           ]) do
      print_sessions_summary(summary, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["observe" | args], opts) do
    {parsed, rest, invalid} =
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

    lines = parsed[:n] || 40

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @observe_usage),
         :ok <- validate_optional_session_type(parsed[:type]),
         :ok <- validate_optional_work_state(parsed[:work_state]),
         :ok <- validate_positive("n", lines),
         :ok <- start_app(opts),
         {:ok, observation_report} <-
           apply(workspace(opts), :observe_sessions, [
             [
               host_name: parsed[:host],
               all_tmux: !parsed[:managed],
               all_processes: parsed[:all_processes] || false,
               type: parsed[:type],
               action: parsed[:action],
               ssh_target: parsed[:ssh_target],
               work_state: parsed[:work_state],
               lines: lines,
               attention: parsed[:attention] || false
             ]
           ]) do
      print_session_observe(observation_report.changes,
        saved: observation_report.saved,
        json: parsed[:json] || false
      )

      :ok
    end
  end

  def run(["changed" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [since: :integer, ref: :string, severity: :string, n: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @changed_usage),
         :ok <- validate_optional_monitor_severity(parsed[:severity]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:list_monitor_events, [
        [
          since_id: parsed[:since],
          ref: parsed[:ref],
          severity: parsed[:severity],
          kinds: MonitorEvents.change_kinds(),
          limit: limit
        ]
      ])
      |> print_monitor_events(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["ready" | args], opts) do
    {parsed, rest, invalid} =
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

    lines = parsed[:lines] || 40
    limit = parsed[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @ready_usage),
         :ok <- validate_optional_session_type(parsed[:type]),
         :ok <- validate_optional_work_board_control(parsed[:control]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts),
         {:ok, report} <-
           apply(workspace(opts), :session_profiles, [
             [
               host_name: parsed[:host],
               project: parsed[:project],
               all_tmux: !parsed[:managed],
               all_processes: parsed[:all_processes] || false,
               type: parsed[:type],
               ssh_target: parsed[:ssh_target],
               control_mode: parsed[:control],
               prompt_status: "ready",
               observe: Keyword.get(parsed, :observe, true),
               lines: lines,
               limit: limit
             ]
           ]) do
      print_session_profiles(report, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["queues" | args], opts) do
    {parsed, rest, invalid} =
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

    lines = parsed[:lines] || 40
    queue_limit = parsed[:n] || 5
    scan_limit = parsed[:scan_limit] || 100

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @queues_usage),
         :ok <- validate_optional_session_type(parsed[:type]),
         :ok <- validate_optional_work_state(parsed[:work_state]),
         :ok <- validate_optional_work_board_control(parsed[:control]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("n", queue_limit),
         :ok <- start_app(opts),
         {:ok, report} <-
           apply(workspace(opts), :session_queues, [
             [
               host_name: parsed[:host],
               project: parsed[:project],
               all_tmux: !parsed[:managed],
               all_processes: parsed[:all_processes] || false,
               type: parsed[:type],
               ssh_target: parsed[:ssh_target],
               work_state: parsed[:work_state],
               control_mode: parsed[:control],
               observe: Keyword.get(parsed, :observe, true),
               lines: lines,
               scan_limit: scan_limit,
               queue_limit: queue_limit
             ]
           ]) do
      print_session_queues(report, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["dossiers" | args], opts) do
    {parsed, rest, invalid} =
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

    lines = parsed[:lines] || 40
    limit = parsed[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @dossiers_usage),
         :ok <- validate_optional_session_type(parsed[:type]),
         :ok <- validate_optional_work_state(parsed[:work_state]),
         :ok <- validate_optional_work_board_control(parsed[:control]),
         :ok <- validate_optional_dossier_next_action(parsed[:next]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts),
         {:ok, report} <-
           apply(workspace(opts), :session_dossiers, [
             [
               ref: parsed[:ref],
               project: parsed[:project],
               host_name: parsed[:host],
               all_tmux: !parsed[:managed],
               all_processes: parsed[:all_processes] || false,
               type: parsed[:type],
               ssh_target: parsed[:ssh_target],
               work_state: parsed[:work_state],
               control_mode: parsed[:control],
               next_action: parsed[:next],
               observe: Keyword.get(parsed, :observe, true),
               lines: lines,
               limit: limit
             ]
           ]) do
      print_session_dossiers(report, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["profiles" | args], opts) do
    {parsed, rest, invalid} =
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

    lines = parsed[:lines] || 40
    limit = parsed[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @profiles_usage),
         :ok <- validate_optional_session_type(parsed[:type]),
         :ok <- validate_optional_work_state(parsed[:work_state]),
         :ok <- validate_optional_work_board_control(parsed[:control]),
         :ok <- validate_optional_dossier_next_action(parsed[:next]),
         :ok <- validate_optional_prompt_status(parsed[:prompt_status]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts),
         {:ok, report} <-
           apply(workspace(opts), :session_profiles, [
             [
               ref: parsed[:ref],
               project: parsed[:project],
               host_name: parsed[:host],
               all_tmux: !parsed[:managed],
               all_processes: parsed[:all_processes] || false,
               type: parsed[:type],
               ssh_target: parsed[:ssh_target],
               work_state: parsed[:work_state],
               control_mode: parsed[:control],
               next_action: parsed[:next],
               prompt_status: parsed[:prompt_status],
               observe: Keyword.get(parsed, :observe, true),
               lines: lines,
               limit: limit
             ]
           ]) do
      print_session_profiles(report, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["reconcile" | args], opts) do
    {parsed, rest, invalid} =
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

    limit = parsed[:n] || 25
    lines = parsed[:lines] || 80
    scan_limit = parsed[:scan_limit] || 100
    remote_limit = parsed[:remote_limit] || 200

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @reconcile_usage),
         :ok <- validate_optional_session_type(parsed[:type]),
         :ok <- validate_optional_work_board_control(parsed[:control]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("remote-limit", remote_limit),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts),
         {:ok, reconciliation} <-
           apply(workspace(opts), :session_reconciliation, [
             [
               host_name: parsed[:host],
               all_tmux: !parsed[:managed],
               all_processes: parsed[:all_processes] || false,
               type: parsed[:type],
               ssh_target: parsed[:ssh_target],
               control_mode: parsed[:control],
               observe: Keyword.get(parsed, :observe, false),
               lines: lines,
               scan_limit: scan_limit,
               remote_limit: remote_limit,
               limit: limit
             ]
           ]) do
      print_session_reconciliation(reconciliation, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["recover" | args], opts) do
    {parsed, rest, invalid} =
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

    limit = parsed[:n] || 25
    lines = parsed[:lines] || 80
    scan_limit = parsed[:scan_limit] || 100
    remote_limit = parsed[:remote_limit] || 200

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @recover_usage),
         :ok <- validate_optional_session_type(parsed[:type]),
         :ok <- validate_optional_work_board_control(parsed[:control]),
         :ok <- validate_positive("lines", lines),
         :ok <- validate_positive("scan-limit", scan_limit),
         :ok <- validate_positive("remote-limit", remote_limit),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts),
         {:ok, recovery} <-
           apply(workspace(opts), :recovery_plan, [
             [
               host_name: parsed[:host],
               all_tmux: !parsed[:managed],
               all_processes: parsed[:all_processes] || false,
               type: parsed[:type],
               ssh_target: parsed[:ssh_target],
               control_mode: parsed[:control],
               observe: Keyword.get(parsed, :observe, false),
               lines: lines,
               scan_limit: scan_limit,
               remote_limit: remote_limit,
               limit: limit
             ]
           ]) do
      print_recovery_plan(recovery, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["history" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [ref: :string, work_state: :string, n: :integer, json: :boolean],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @history_usage),
         :ok <- validate_optional_work_state(parsed[:work_state]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:list_session_observations, [
        [ref: parsed[:ref], work_state: parsed[:work_state], limit: limit]
      ])
      |> print_session_history(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["changes" | args], opts) do
    {parsed, rest, invalid} =
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

    limit = parsed[:n] || 20

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @changes_usage),
         :ok <- validate_optional_work_state(parsed[:work_state]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:list_session_changes, [
        [
          ref: parsed[:ref],
          work_state: parsed[:work_state],
          attention: parsed[:attention] || false,
          limit: limit
        ]
      ])
      |> print_session_changes(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["stale" | args], opts) do
    {parsed, rest, invalid} =
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

    limit = parsed[:n] || 20
    stale_after_seconds = parsed[:seconds] || 300

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @stale_usage),
         :ok <- validate_optional_session_type(parsed[:type]),
         :ok <- validate_optional_work_state(parsed[:work_state]),
         :ok <- validate_positive("seconds", stale_after_seconds),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:list_stale_session_observations, [
        [
          ref: parsed[:ref],
          host: parsed[:host],
          type: parsed[:type],
          work_state: parsed[:work_state],
          stale_after_seconds: stale_after_seconds,
          limit: limit
        ]
      ])
      |> print_stale_sessions(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["broadcast" | args], opts) do
    {parsed, message_parts, invalid} =
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

    lines = parsed[:n] || 40
    message = message_parts |> Enum.join(" ") |> String.trim()

    with :ok <- validate_options(invalid),
         {:ok, message} <- required_message(message, @broadcast_usage),
         :ok <- validate_optional_session_type(parsed[:type]),
         :ok <- validate_optional_work_state(parsed[:work_state]),
         :ok <- validate_positive("n", lines),
         :ok <- start_app(opts),
         {:ok, report} <-
           apply(workspace(opts), :broadcast_sessions, [
             message,
             [
               host_name: parsed[:host],
               all_tmux: !parsed[:managed],
               all_processes: parsed[:all_processes] || false,
               type: parsed[:type],
               action: parsed[:action],
               ssh_target: parsed[:ssh_target],
               work_state: parsed[:work_state],
               attention: parsed[:attention] || false,
               lines: lines,
               execute: parsed[:yes] || false,
               enter: !parsed[:no_enter]
             ]
           ]) do
      print_broadcast_report(report, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["remote" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          target: :string,
          probe: :boolean,
          force: :boolean,
          timeout_ms: :integer,
          json: :boolean
        ]
      )

    timeout_ms = parsed[:timeout_ms] || 5_000

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @remote_usage),
         :ok <- validate_positive("timeout-ms", timeout_ms),
         :ok <- start_app(opts) do
      if parsed[:probe] do
        with {:ok, probes} <-
               apply(workspace(opts), :probe_remote_sessions, [
                 [
                   target: parsed[:target],
                   timeout_ms: timeout_ms,
                   force: parsed[:force] || false
                 ]
               ]) do
          print_sessions_remote_probes(probes, json: parsed[:json] || false)
          :ok
        end
      else
        with {:ok, candidates} <-
               apply(workspace(opts), :remote_session_candidates, [[target: parsed[:target]]]) do
          print_sessions_remote_candidates(candidates, json: parsed[:json] || false)
          :ok
        end
      end
    end
  end

  def run(["ls" | args], opts) do
    {parsed, rest, invalid} =
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

    limit = parsed[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @runner_sessions_ls_usage),
         :ok <- validate_optional_runner_session_status(parsed[:status]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:list_runner_sessions, [
        [
          status: parsed[:status],
          runner_id: parsed[:runner],
          workspace_id: parsed[:workspace],
          assignment_id: parsed[:assignment],
          limit: limit
        ]
      ])
      |> print_runner_sessions(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["show", session_id | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @runner_session_show_usage),
         :ok <- start_app(opts),
         session when not is_nil(session) <-
           apply(workspace(opts), :get_runner_session, [session_id]) do
      print_runner_session("session", session, json: parsed[:json] || false)
      :ok
    else
      nil -> {:error, :runner_session_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def run(["logs", session_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [lines: :integer, json: :boolean])

    lines = parsed[:lines] || 80

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @runner_session_logs_usage),
         :ok <- validate_positive("lines", lines),
         :ok <- start_app(opts),
         {:ok, result} <-
           apply(workspace(opts), :runner_session_logs, [session_id, [lines: lines]]) do
      print_runner_session_logs(result, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["attach", session_id | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @runner_session_attach_usage),
         :ok <- start_app(opts),
         {:ok, result} <- apply(workspace(opts), :runner_session_attach_plan, [session_id]) do
      print_runner_session_attach(result, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["expire" | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @runner_session_expire_usage),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:expire_runner_sessions, [])
      |> print_runner_session_expiration(json: parsed[:json] || false)

      :ok
    end
  end

  def run(args, opts) do
    {parsed, rest, invalid} =
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
         :ok <- expect_no_args(rest, @sessions_usage),
         :ok <- validate_optional_session_type(parsed[:type]),
         :ok <- start_app(opts),
         {:ok, report} <-
           apply(workspace(opts), :list_sessions, [
             [
               host_name: parsed[:host],
               all_tmux: !parsed[:managed],
               all_processes: parsed[:all_processes] || false,
               type: parsed[:type],
               action: parsed[:action],
               ssh_target: parsed[:ssh_target]
             ]
           ]) do
      print_sessions_report(report, json: parsed[:json] || false)
      :ok
    end
  end

  defp workspace(opts), do: Keyword.get(opts, :workspace, Workspace)

  defp start_app(opts) do
    case Keyword.fetch(opts, :start_app) do
      {:ok, start_app} -> start_app.()
      :error -> {:error, :missing_start_app_callback}
    end
  end

  defp maybe_save_snapshot(_opts, _report, false), do: {:ok, nil}

  defp maybe_save_snapshot(opts, report, true) do
    with {:ok, observations} <- apply(workspace(opts), :record_session_observations, [report]) do
      {:ok, length(observations)}
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

  defp validate_optional_work_board_control(nil), do: :ok
  defp validate_optional_work_board_control("uncontrolled"), do: :ok
  defp validate_optional_work_board_control(mode), do: validate_session_control_mode(mode)

  defp validate_session_control_mode(mode) do
    if mode in JX.SessionControls.modes() do
      :ok
    else
      {:error,
       "unsupported session control mode #{inspect(mode)}; expected one of: #{Enum.join(JX.SessionControls.modes(), ", ")}"}
    end
  end

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

  defp validate_optional_runner_session_status(nil), do: :ok

  defp validate_optional_runner_session_status(status)
       when status in ~w(created claimed running progressed completed failed stale expired ended active all),
       do: :ok

  defp validate_optional_runner_session_status(status),
    do:
      {:error,
       "unsupported session status #{inspect(status)}; expected created, claimed, running, progressed, completed, failed, stale, expired, ended, active, or all"}

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp required_message(message, _usage) when is_binary(message) and message != "" do
    {:ok, message}
  end

  defp required_message(_message, usage), do: {:error, "usage: #{usage}"}

  defp print_sessions_report(%{sessions: [], errors: []}, opts) do
    if opts[:json], do: print_json(%{sessions: [], errors: []}), else: IO.puts("no sessions")
  end

  defp print_sessions_report(%{sessions: sessions, errors: errors}, opts) do
    if opts[:json] do
      print_json(%{sessions: sessions, errors: Enum.map(errors, &json_error/1)})
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

    print_summary_errors_if_present(errors, sessions != [])
  end

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

  defp print_sessions_snapshot(%{sessions: sessions, errors: errors} = report, opts) do
    if opts[:json] do
      %{sessions: sessions, errors: Enum.map(errors, &json_error/1)}
      |> maybe_compact_snapshot(report, opts[:compact])
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
    if opts[:json], do: print_json(%{changes: []}), else: IO.puts("no session changes")
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
      print_json(%{saved: opts[:saved], changes: Enum.map(changes, &json_session_change/1)})
    else
      print_session_changes(changes, json: false)
      print_saved_count(opts[:saved])
    end
  end

  defp print_session_dossiers(%{dossiers: [], errors: []} = report, opts) do
    if opts[:json],
      do: print_json(json_session_dossiers(report)),
      else: IO.puts("no session dossiers")
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
      print_summary_errors_after(report.errors)
    end
  end

  defp print_session_queues(%{queues: [], errors: []} = report, opts) do
    if opts[:json],
      do: print_json(json_session_queues(report)),
      else: IO.puts("no session queues")
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
      print_summary_errors_after(report.errors)
    end
  end

  defp print_session_profiles(%{profiles: [], errors: []} = report, opts) do
    if opts[:json],
      do: print_json(json_session_profiles(report)),
      else: IO.puts("no session profiles")
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
      print_summary_errors_after(report.errors)
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

      print_summary_errors_after(reconciliation.errors)
    end
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

  defp print_monitor_events([], opts) do
    if opts[:json], do: print_json(%{events: []}), else: IO.puts("no monitor events")
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

  defp print_stale_sessions([], opts) do
    if opts[:json], do: print_json(%{stale: []}), else: IO.puts("no stale session observations")
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
    print_summary_errors(errors)
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
      Enum.each(packets, &IO.puts("  #{&1.session_id} #{&1.assignment_id} #{&1.runner_id}"))
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

    print_summary_errors_if_present(errors, sessions != [])
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

  defp print_registry_warnings(%{warnings: warnings}),
    do: IO.puts("warnings: #{Enum.join(warnings, "; ")}")

  defp print_registry_warnings(_registry), do: :ok

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

  defp print_summary_errors_after([]), do: :ok

  defp print_summary_errors_after(errors) do
    IO.puts("")
    print_summary_errors(errors)
  end

  defp print_summary_errors_if_present([], _spaced?), do: :ok

  defp print_summary_errors_if_present(errors, spaced?) do
    if spaced?, do: IO.puts("")
    print_summary_errors(errors)
  end

  defp print_summary_errors(errors) do
    rows =
      Enum.map(errors, fn error ->
        [
          Map.get(error, :host, ""),
          Map.get(error, :transport, ""),
          Map.get(error, :subsystem, ""),
          format_error(Map.get(error, :error, ""))
        ]
      end)

    print_table(["HOST", "TRANSPORT", "SUBSYSTEM", "ERROR"], rows)
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

  defp summary_value(value) when is_integer(value), do: Integer.to_string(value)
  defp summary_value(value) when is_boolean(value), do: format_bool(value)
  defp summary_value(value) when is_binary(value), do: value
  defp summary_value(%_struct{} = value), do: to_string(value)
  defp summary_value(nil), do: ""
  defp summary_value(value), do: inspect(value)

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

  defp json_monitor_event(event) do
    %{
      id: event.id,
      event_id: event.event_id,
      kind: event.kind,
      severity: event.severity,
      ref: event.ref,
      project: event.project,
      work_state: event.work_state,
      action: event.action,
      summary: event.summary,
      payload: decode_json_text(event.payload),
      inserted_at: format_time(event.inserted_at)
    }
  end

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

  defp json_runner_session(%{} = session),
    do: Map.put_new(session, :next, runner_session_next(session))

  defp runner_session_next(%{status: status, session_id: id})
       when status in ["claimed", "running", "progressed", "stale"],
       do: "jx sessions show #{id}"

  defp runner_session_next(%{session_id: id}), do: "jx timeline session #{id}"

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

  defp maybe_compact_snapshot(packet, _report, true) do
    %{packet | sessions: Enum.map(packet.sessions, &compact_snapshot_session/1)}
  end

  defp maybe_compact_snapshot(packet, _report, _compact?), do: packet

  defp maybe_put_saved(report, nil), do: report
  defp maybe_put_saved(report, saved), do: Map.put(report, :saved, saved)

  defp compact_snapshot_session(session) do
    capture = Map.get(session, :capture, %{})

    compact_capture =
      capture
      |> Map.drop([:output])
      |> Map.put_new(:summary, JX.SessionStatus.summary(Map.get(capture, :output, "")))

    Map.put(session, :capture, compact_capture)
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
    JX.SessionStatus.summary(output, 160)
  end

  defp capture_summary(%{capture: %{error: error}}), do: truncate(error, 160)
  defp capture_summary(_session), do: ""

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

  defp first_present(values) do
    Enum.find_value(values, "", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end)
  end

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

  defp format_active(true), do: "yes"
  defp format_active(false), do: "no"
  defp format_active(nil), do: "-"

  defp format_bool(true), do: "yes"
  defp format_bool(false), do: "no"

  defp format_attention(true), do: "yes"
  defp format_attention(false), do: "no"

  defp format_optional_integer(nil), do: ""
  defp format_optional_integer(integer), do: Integer.to_string(integer)

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp format_time(value) when is_binary(value), do: if(value == "", do: "-", else: value)

  defp blank_to_dash(value) when value in [nil, ""], do: "-"
  defp blank_to_dash(value), do: to_string(value)

  defp plural(1), do: ""
  defp plural(_count), do: "s"

  defp print_saved_count(nil), do: :ok
  defp print_saved_count(count), do: IO.puts("saved #{count} observations")

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp truncate(value, max_length) do
    value = value || ""

    if String.length(value) > max_length do
      String.slice(value, 0, max_length - 3) <> "..."
    else
      value
    end
  end
end
