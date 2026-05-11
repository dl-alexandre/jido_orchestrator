defmodule JX.DelegatedExecution do
  @moduledoc """
  Durable delegated execution lane for existing approval-gated safe actions.

  Delegated execution never creates new safe-action kinds, shell commands, argv,
  or generic remote execution. Assignments can target only existing JX safe
  actions, and execution still flows through `JX.SafeActions.execute/2`.
  """

  import Ecto.Query

  alias JX.DelegatedExecution.{Agent, Assignment, Report, Runner, RunnerReport, RunnerSession}
  alias JX.DevIDE.{Client, RunnerProtocol}
  alias JX.OperationalEvents
  alias JX.OperationalLeases
  alias JX.OperationalLeases.Lease
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Repo
  alias JX.SafeActions
  alias JX.SafeActions.Audit

  @agent_prefix "agent-"
  @assignment_prefix "asgn-"
  @report_prefix "drep-"
  @runner_prefix "runner-"
  @runner_session_prefix "rsess-"
  @runner_report_prefix "rrep-"
  @default_assignment_ttl_seconds 30 * 60

  def agent_statuses, do: Agent.statuses()
  def assignment_statuses, do: Assignment.statuses()
  def runner_statuses, do: Runner.statuses()
  def runner_session_statuses, do: RunnerSession.statuses()

  def register_agent(attrs) do
    attrs = Map.new(attrs)
    now = Map.get(attrs, :now, DateTime.utc_now())
    agent_id = clean(Map.get(attrs, :agent_id, agent_id()))

    attrs =
      attrs
      |> Map.put(:agent_id, agent_id)
      |> Map.put_new(:name, agent_id)
      |> Map.put_new(:status, "idle")
      |> Map.put_new(:capabilities, [])
      |> Map.put_new(:workspace_affinity, [])
      |> Map.put_new(:heartbeat_ttl_seconds, 120)
      |> Map.put_new(:metadata, %{})
      |> Map.put(:last_heartbeat_at, now)
      |> encode_json_field(:capabilities, [])
      |> encode_json_field(:workspace_affinity, [])
      |> encode_json_field(:metadata, %{})

    Repo.transaction(fn ->
      agent =
        (Repo.get_by(Agent, agent_id: agent_id) || %Agent{})
        |> Agent.changeset(attrs)
        |> Repo.insert_or_update()
        |> unwrap_insert()

      _ = record_agent(agent, "agent.registered")
      agent
    end)
    |> unwrap_transaction()
  end

  def heartbeat(agent_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case Repo.get_by(Agent, agent_id: clean(agent_id)) do
      nil ->
        {:error, :agent_not_found}

      %Agent{} = agent ->
        attrs =
          %{
            last_heartbeat_at: now,
            status: heartbeat_status(agent)
          }
          |> maybe_put(:capabilities, Keyword.get(opts, :capabilities))
          |> maybe_put(:workspace_affinity, Keyword.get(opts, :workspace_affinity))
          |> maybe_put(:metadata, Keyword.get(opts, :metadata))
          |> maybe_encode_json_field(:capabilities)
          |> maybe_encode_json_field(:workspace_affinity)
          |> maybe_encode_json_field(:metadata)

        Repo.transaction(fn ->
          agent =
            agent
            |> Agent.changeset(attrs)
            |> Repo.update()
            |> unwrap_insert()

          _ = record_agent(agent, "agent.heartbeat")
          agent
        end)
        |> unwrap_transaction()
    end
  end

  def list_agents(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 50)
    status = Keyword.get(opts, :status)

    Agent
    |> maybe_filter_agent_status(status)
    |> order_by([agent], asc: agent.agent_id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&agent_summary(&1, now))
    |> maybe_filter_summary_status(status)
  end

  def register_runner(attrs) do
    attrs = Map.new(attrs)
    now = Map.get(attrs, :now, DateTime.utc_now())
    runner_id = clean(Map.get(attrs, :runner_id, runner_id()))
    agent_id = clean(Map.get(attrs, :agent_id, "#{runner_id}:agent"))

    attrs =
      attrs
      |> Map.put(:runner_id, runner_id)
      |> Map.put(:agent_id, agent_id)
      |> Map.put_new(:host_name, "")
      |> Map.put_new(:status, "idle")
      |> Map.put_new(:capabilities, [])
      |> Map.put_new(:workspace_affinity, [])
      |> Map.put_new(:heartbeat_ttl_seconds, 120)
      |> Map.put_new(:tmux_server, "jx")
      |> Map.put_new(:tmux_session_prefix, "jx-#{runner_id}")
      |> Map.put_new(:metadata, %{})
      |> Map.put(:last_heartbeat_at, now)
      |> encode_json_field(:capabilities, [])
      |> encode_json_field(:workspace_affinity, [])
      |> encode_json_field(:metadata, %{})

    Repo.transaction(fn ->
      runner =
        (Repo.get_by(Runner, runner_id: runner_id) || %Runner{})
        |> Runner.changeset(attrs)
        |> Repo.insert_or_update()
        |> unwrap_insert()

      _ = ensure_agent_for_runner(runner, now)
      _ = record_runner(runner, "runner.registered")
      runner
    end)
    |> unwrap_transaction()
  end

  def heartbeat_runner(runner_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case Repo.get_by(Runner, runner_id: clean(runner_id)) do
      nil ->
        {:error, :runner_not_found}

      %Runner{} = runner ->
        attrs =
          %{
            last_heartbeat_at: now,
            status: runner_heartbeat_status(runner),
            metadata:
              runner
              |> decode_metadata()
              |> Map.merge(Map.new(Keyword.get(opts, :metadata, %{})))
          }
          |> maybe_put(:capabilities, Keyword.get(opts, :capabilities))
          |> maybe_put(:workspace_affinity, Keyword.get(opts, :workspace_affinity))
          |> maybe_encode_json_field(:capabilities)
          |> maybe_encode_json_field(:workspace_affinity)
          |> maybe_encode_json_field(:metadata)

        Repo.transaction(fn ->
          runner =
            runner
            |> Runner.changeset(attrs)
            |> Repo.update()
            |> unwrap_insert()

          _ = ensure_agent_for_runner(runner, now)
          _ = record_runner(runner, "runner.heartbeat")

          case Keyword.get(opts, :session_id) do
            nil -> :ok
            session_id -> _ = heartbeat_runner_session(session_id, runner.runner_id, now: now)
          end

          runner
        end)
        |> unwrap_transaction()
    end
  end

  def list_runners(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 50)
    status = Keyword.get(opts, :status)

    _ = expire_runner_sessions(now: now)

    Runner
    |> maybe_filter_runner_status(status)
    |> order_by([runner], asc: runner.runner_id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&runner_summary(&1, now))
    |> maybe_filter_summary_status(status)
  end

  def get_runner(runner_id), do: Repo.get_by(Runner, runner_id: clean(runner_id))

  def claim_runner_assignment(assignment_id, runner_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Repo.transaction(fn ->
      with %Assignment{} = assignment <- Repo.get_by(Assignment, assignment_id: assignment_id),
           %Runner{} = runner <- Repo.get_by(Runner, runner_id: clean(runner_id)),
           :ok <- ensure_runner_live(runner, now),
           :ok <- ensure_runner_capable(runner, assignment),
           {:ok, session} <- ensure_runner_session_available(assignment, runner, now, opts),
           {:ok, claimed} <- claim_assignment(assignment.assignment_id, runner.agent_id, opts) do
        claimed =
          claimed
          |> Assignment.changeset(%{
            runner_id: runner.runner_id,
            session_id: session.session_id
          })
          |> Repo.update()
          |> unwrap_insert()

        session =
          session
          |> RunnerSession.changeset(%{
            status: "claimed",
            heartbeat_at: now,
            expires_at: runner_session_expires_at(runner, now),
            last_summary: "assignment #{assignment.assignment_id} claimed"
          })
          |> Repo.update()
          |> unwrap_insert()

        _ = update_runner_status(runner, "busy")

        _ =
          record_runner_session(session, "runner_session.claimed",
            payload: %{assignment: assignment_payload(claimed)}
          )

        %{assignment: claimed, session: session}
      else
        nil -> Repo.rollback(:assignment_or_runner_not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  def start_runner_session(session_id, runner_id, opts \\ []) do
    update_owned_runner_session(session_id, runner_id, "runner_session.started", opts, fn session,
                                                                                          runner,
                                                                                          now ->
      with {:ok, assignment} <- start_assignment(session.assignment_id, runner.agent_id, opts) do
        {:ok,
         %{
           attrs: %{
             status: "running",
             started_at: session.started_at || now,
             heartbeat_at: now,
             expires_at: runner_session_expires_at(runner, now),
             last_summary: assignment.summary
           },
           payload: %{assignment: assignment_payload(assignment)}
         }}
      end
    end)
  end

  def progress_runner_session(session_id, runner_id, summary, opts \\ []) do
    update_owned_runner_session(
      session_id,
      runner_id,
      "runner_session.progressed",
      opts,
      fn session, runner, now ->
        with {:ok, assignment} <-
               progress_assignment(session.assignment_id, runner.agent_id, summary, opts) do
          {:ok,
           %{
             attrs: %{
               status: "progressed",
               heartbeat_at: now,
               expires_at: runner_session_expires_at(runner, now),
               last_summary: clean(summary)
             },
             payload: %{assignment: assignment_payload(assignment)}
           }}
        end
      end
    )
  end

  def execute_runner_session(session_id, runner_id, opts \\ []) do
    if Keyword.get(opts, :confirm, false) do
      update_owned_runner_session(
        session_id,
        runner_id,
        "runner_session.completed",
        opts,
        fn session, runner, now ->
          with {:ok, assignment} <-
                 execute_assignment(session.assignment_id, runner.agent_id, opts) do
            {:ok,
             %{
               attrs: %{
                 status: "completed",
                 active_assignment_key: nil,
                 heartbeat_at: now,
                 ended_at: now,
                 last_summary: assignment.summary
               },
               payload: %{assignment: assignment_payload(assignment)}
             }}
          else
            {:error, reason} ->
              {:ok,
               %{
                 kind: "runner_session.failed",
                 attrs: %{
                   status: "failed",
                   active_assignment_key: nil,
                   heartbeat_at: now,
                   ended_at: now,
                   last_summary: inspect(reason)
                 },
                 payload: %{reason: inspect(reason)}
               }}
          end
        end
      )
    else
      {:error, :confirmation_required}
    end
  end

  def fail_runner_session(session_id, runner_id, summary, opts \\ []) do
    update_owned_runner_session(session_id, runner_id, "runner_session.failed", opts, fn session,
                                                                                         runner,
                                                                                         now ->
      with {:ok, assignment} <-
             fail_assignment(session.assignment_id, runner.agent_id, summary, opts) do
        {:ok,
         %{
           attrs: %{
             status: "failed",
             active_assignment_key: nil,
             heartbeat_at: now,
             ended_at: now,
             last_summary: clean(summary)
           },
           payload: %{assignment: assignment_payload(assignment)}
         }}
      end
    end)
  end

  def heartbeat_runner_session(session_id, runner_id, opts \\ []) do
    update_owned_runner_session(
      session_id,
      runner_id,
      "runner_session.heartbeat",
      opts,
      fn _session, runner, now ->
        {:ok,
         %{
           attrs: %{
             heartbeat_at: now,
             expires_at: runner_session_expires_at(runner, now)
           },
           payload: Keyword.get(opts, :payload, %{})
         }}
      end
    )
  end

  def list_runner_sessions(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 50)

    _ = expire_runner_sessions(now: now)

    RunnerSession
    |> maybe_filter_runner_session_status(Keyword.get(opts, :status))
    |> maybe_filter_runner_session_runner(Keyword.get(opts, :runner_id))
    |> maybe_filter_runner_session_workspace(Keyword.get(opts, :workspace_id))
    |> maybe_filter_runner_session_assignment(Keyword.get(opts, :assignment_id))
    |> order_by([session],
      asc:
        fragment(
          "case ? when 'claimed' then 0 when 'running' then 1 when 'progressed' then 2 when 'created' then 3 when 'stale' then 4 when 'failed' then 5 when 'expired' then 6 else 7 end",
          session.status
        ),
      desc: session.updated_at
    )
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&runner_session_summary(&1, now))
  end

  def get_runner_session(session_id),
    do: Repo.get_by(RunnerSession, session_id: clean(session_id))

  def runner_session_logs(session_id, opts \\ []) do
    case Repo.get_by(RunnerSession, session_id: clean(session_id)) do
      nil ->
        {:error, :runner_session_not_found}

      %RunnerSession{} = session ->
        payload = %{lines: Keyword.get(opts, :lines, 80), log_path: session.log_path}
        _ = record_runner_session(session, "runner_session.logs", payload: payload)

        {:ok,
         %{
           session: session,
           log_path: session.log_path,
           tmux_server: session.tmux_server,
           tmux_session_name: session.tmux_session_name,
           note: "stored log metadata only; no remote command executed"
         }}
    end
  end

  def runner_session_attach_plan(session_id, opts \\ []) do
    case Repo.get_by(RunnerSession, session_id: clean(session_id)) do
      nil ->
        {:error, :runner_session_not_found}

      %RunnerSession{} = session ->
        command =
          ["tmux", "-L", session.tmux_server, "attach", "-t", session.tmux_session_name]
          |> Enum.map_join(" ", &shell_quote/1)

        _ =
          record_runner_session(session, "runner_session.attach",
            payload: %{command: command, explicit: Keyword.get(opts, :explicit, true)}
          )

        {:ok,
         %{
           session: session,
           command: command,
           note: "attach is explicit; jx did not execute tmux"
         }}
    end
  end

  def expire_runner_sessions(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    stale_runner_ids =
      Runner
      |> Repo.all()
      |> Enum.filter(&stale_runner?(&1, now))
      |> Enum.map(& &1.runner_id)

    RunnerSession
    |> where([session], session.status in ^RunnerSession.active_statuses())
    |> where(
      [session],
      session.expires_at <= ^now or session.runner_id in ^stale_runner_ids
    )
    |> Repo.all()
    |> Enum.map(&expire_runner_session(&1, now))
  end

  def create_assignment(action_id, opts \\ []) do
    with {:ok, action} <- fetch_safe_action(action_id),
         :ok <- ensure_assignable_action(action) do
      payload = Audit.payload(action)

      attrs = %{
        assignment_id: assignment_id(),
        action_id: action.action_id,
        approval_id: action.ref,
        workspace_id: text_field(payload, "workspace_id"),
        safe_action_kind: action.action,
        status: "created",
        correlation_id: Audit.correlation_id(action),
        required_capabilities: encode_json(required_capabilities(action)),
        summary: Keyword.get(opts, :summary, "delegate safe action #{action.action_id}"),
        metadata:
          encode_json(%{
            action: action.action,
            target: action.target,
            created_by: Keyword.get(opts, :created_by, "operator"),
            runtime: Keyword.get(opts, :runtime, %{}),
            routing: runner_requirements(opts)
          }),
        expires_at:
          DateTime.add(
            Keyword.get(opts, :now, DateTime.utc_now()),
            Keyword.get(opts, :ttl_seconds, @default_assignment_ttl_seconds),
            :second
          )
      }

      Repo.transaction(fn ->
        case active_assignment_for_action(action.action_id) do
          %Assignment{} = assignment ->
            assignment

          nil ->
            assignment =
              %Assignment{}
              |> Assignment.changeset(attrs)
              |> Repo.insert()
              |> unwrap_insert()

            _ = record_assignment(assignment, "assignment.created")
            assignment
        end
      end)
      |> unwrap_transaction()
    end
  end

  def enqueue_devide_runner_assignment(assignment_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with %Assignment{} = assignment <-
           Repo.get_by(Assignment, assignment_id: clean(assignment_id)),
         {:ok, action} <- fetch_safe_action(assignment.action_id),
         :ok <- ensure_devide_runner_assignable(assignment, action),
         payload <- Audit.payload(action),
         command_id when command_id != "" <- text_field(payload, "command_id"),
         {:ok, envelope} <-
           Client.enqueue_runner_assignment_envelope(
             Keyword.get_lazy(opts, :client, &Client.new/0),
             assignment.workspace_id,
             command_id,
             correlation_id: assignment.correlation_id,
             jx_assignment_id: assignment.assignment_id,
             jx_action_id: assignment.action_id,
             jx_safe_action_kind: assignment.safe_action_kind,
             runner_requirements: assignment_runner_requirements(assignment)
           ),
         {:ok, devide_assignment} <-
           validate_devide_runner_enqueue(envelope, assignment, command_id) do
      record_devide_runner_enqueued(assignment, envelope, devide_assignment, now)
    else
      nil ->
        {:error, :assignment_not_found}

      "" ->
        {:error, :missing_command_id}

      {:error, reason} = error ->
        _ = record_devide_runner_enqueue_failed(assignment_id, reason)
        error
    end
  end

  def reconcile_devide_runner_assignment(devide_assignment_id, opts \\ []) do
    with {:ok, replay} <-
           Client.runner_assignment_replay(
             Keyword.get_lazy(opts, :client, &Client.new/0),
             devide_assignment_id
           ) do
      reconcile_devide_runner_replay(replay, opts)
    end
  end

  def reconcile_devide_runner_replay(replay, opts \\ [])

  def reconcile_devide_runner_replay(replay, opts) when is_map(replay) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, devide_assignment} <- replay_assignment(replay),
         {:ok, jx_assignment_id} <- replay_jx_assignment_id(devide_assignment, opts),
         %Assignment{} = assignment <- Repo.get_by(Assignment, assignment_id: jx_assignment_id),
         :ok <- validate_devide_runner_replay(replay, assignment) do
      reports = replay_reports(replay)

      Repo.transaction(fn ->
        assignment =
          assignment
          |> Assignment.changeset(reconciled_assignment_attrs(assignment, devide_assignment, now))
          |> Repo.update()
          |> unwrap_insert()

        if assignment.status in ["completed", "failed", "expired"] do
          _ = maybe_release_lease(assignment, assignment.claimant_agent_id)
        end

        Enum.each(reports, &record_devide_runner_report_once(assignment, devide_assignment, &1))
        _ = record_devide_runner_reconciled_once(assignment, devide_assignment, reports)
        assignment
      end)
      |> unwrap_transaction()
    else
      nil ->
        {:error, :assignment_not_found}

      {:error, reason} = error ->
        _ = record_devide_runner_replay_mismatch(replay, opts, reason)
        error
    end
  end

  def reconcile_devide_runner_replay(_replay, _opts), do: {:error, :invalid_replay}

  def reconcile_devide_runner_assignments(opts \\ []) do
    opts
    |> devide_runner_reconciliation_targets()
    |> Enum.map(fn assignment ->
      assignment
      |> assignment_runner_id()
      |> reconcile_devide_runner_assignment(
        Keyword.merge(opts, assignment_id: assignment.assignment_id)
      )
    end)
  end

  def list_assignments(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 50)

    _ = expire_assignments(now: now)

    Assignment
    |> maybe_filter_assignment_status(Keyword.get(opts, :status))
    |> maybe_filter_assignment_agent(Keyword.get(opts, :agent_id))
    |> maybe_filter_workspace(Keyword.get(opts, :workspace_id))
    |> order_by([assignment],
      asc:
        fragment(
          "case ? when 'created' then 0 when 'claimed' then 1 when 'started' then 2 when 'progressed' then 3 when 'failed' then 4 else 5 end",
          assignment.status
        ),
      desc: assignment.updated_at
    )
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&assignment_summary(&1, now))
  end

  def get_assignment(assignment_id), do: Repo.get_by(Assignment, assignment_id: assignment_id)

  def claim_assignment(assignment_id, agent_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Repo.transaction(fn ->
      with %Assignment{} = assignment <- Repo.get_by(Assignment, assignment_id: assignment_id),
           %Agent{} = agent <- Repo.get_by(Agent, agent_id: clean(agent_id)),
           :ok <- ensure_assignment_open(assignment),
           :ok <- ensure_agent_live(agent, now),
           :ok <- ensure_agent_capable(agent, assignment),
           {:ok, lease} <- ensure_action_lease(assignment, agent, now, opts) do
        assignment =
          assignment
          |> Assignment.changeset(%{
            status: "claimed",
            active_claim_key: active_claim_key(assignment.assignment_id),
            claimant_agent_id: agent.agent_id,
            lease_id: lease.lease_id,
            claimed_at: now
          })
          |> Repo.update()
          |> unwrap_insert()

        _ = update_agent_status(agent, "busy")
        _ = record_assignment(assignment, "assignment.claimed", agent: agent)
        assignment
      else
        nil -> Repo.rollback(:assignment_or_agent_not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  def start_assignment(assignment_id, agent_id, opts \\ []) do
    update_claimed_assignment(assignment_id, agent_id, "assignment.started", opts, fn assignment,
                                                                                      now ->
      %{status: "started", started_at: assignment.started_at || now}
    end)
  end

  def progress_assignment(assignment_id, agent_id, summary, opts \\ []) do
    update_claimed_assignment(
      assignment_id,
      agent_id,
      "assignment.progressed",
      opts,
      fn _assignment, now ->
        %{status: "progressed", summary: clean(summary), last_report_at: now}
      end
    )
  end

  def execute_assignment(assignment_id, agent_id, opts \\ []) do
    if Keyword.get(opts, :confirm, false) do
      do_execute_assignment(assignment_id, agent_id, opts)
    else
      {:error, :confirmation_required}
    end
  end

  def fail_assignment(assignment_id, agent_id, summary, opts \\ []) do
    update_claimed_assignment(assignment_id, agent_id, "assignment.failed", opts, fn _assignment,
                                                                                     now ->
      %{
        status: "failed",
        summary: clean(summary),
        active_claim_key: nil,
        completed_at: now,
        last_report_at: now
      }
    end)
  end

  def expire_assignments(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    stale_agent_ids =
      Agent
      |> Repo.all()
      |> Enum.filter(&stale_agent?(&1, now))
      |> Enum.map(& &1.agent_id)

    Assignment
    |> where([assignment], assignment.status in ^Assignment.active_statuses())
    |> where(
      [assignment],
      assignment.expires_at <= ^now or assignment.claimant_agent_id in ^stale_agent_ids
    )
    |> Repo.all()
    |> Enum.map(&expire_assignment(&1, now))
  end

  def reports_for_assignment(assignment_id) do
    Report
    |> where([report], report.assignment_id == ^assignment_id)
    |> order_by([report], asc: report.id)
    |> Repo.all()
  end

  defp ensure_agent_for_runner(%Runner{} = runner, now) do
    attrs = %{
      agent_id: runner.agent_id,
      name: runner.agent_id,
      status: runner_agent_status(runner, now),
      capabilities: runner.capabilities,
      workspace_affinity: runner.workspace_affinity,
      heartbeat_ttl_seconds: runner.heartbeat_ttl_seconds,
      last_heartbeat_at: runner.last_heartbeat_at || now,
      metadata:
        encode_json(%{
          runner_id: runner.runner_id,
          host_name: runner.host_name,
          source: "runner"
        })
    }

    (Repo.get_by(Agent, agent_id: runner.agent_id) || %Agent{})
    |> Agent.changeset(attrs)
    |> Repo.insert_or_update()
  end

  defp ensure_runner_session_available(%Assignment{} = assignment, %Runner{} = runner, now, opts) do
    case active_runner_session_for_assignment(assignment.assignment_id) do
      %RunnerSession{runner_id: runner_id} = session when runner_id == runner.runner_id ->
        session =
          session
          |> RunnerSession.changeset(%{
            status: "claimed",
            heartbeat_at: now,
            expires_at: runner_session_expires_at(runner, now),
            metadata: merged_session_metadata(session, opts)
          })
          |> Repo.update()
          |> unwrap_insert()

        _ = record_runner_session(session, "runner_session.reconnected")
        {:ok, session}

      %RunnerSession{} = session ->
        {:error, {:runner_session_conflict, session}}

      nil ->
        session_attrs =
          runner_session_attrs(assignment, runner, now, opts)

        session =
          %RunnerSession{}
          |> RunnerSession.changeset(session_attrs)
          |> Repo.insert()
          |> unwrap_insert()

        _ = record_runner_session(session, "runner_session.created")
        {:ok, session}
    end
  end

  defp update_owned_runner_session(session_id, runner_id, kind, opts, update_fun) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Repo.transaction(fn ->
      with %RunnerSession{} = session <- Repo.get_by(RunnerSession, session_id: clean(session_id)),
           %Runner{} = runner <- Repo.get_by(Runner, runner_id: clean(runner_id)),
           :ok <- ensure_runner_owns_session(runner, session),
           :ok <- ensure_runner_live(runner, now),
           :ok <- ensure_runner_session_active(session),
           {:ok, update} <- update_fun.(session, runner, now) do
        attrs = Map.get(update, :attrs, %{})
        payload = Map.get(update, :payload, %{})

        session =
          session
          |> RunnerSession.changeset(attrs)
          |> Repo.update()
          |> unwrap_insert()

        event_kind = Map.get(update, :kind, kind)

        _ = update_runner_status(runner, runner_status_after_session(session))
        _ = record_runner_session(session, event_kind, payload: payload)
        session
      else
        nil -> Repo.rollback(:runner_session_or_runner_not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  defp expire_runner_session(%RunnerSession{} = session, now) do
    Repo.transaction(fn ->
      session =
        session
        |> RunnerSession.changeset(%{
          status: "expired",
          active_assignment_key: nil,
          ended_at: now,
          last_summary: "runner session expired or runner stale"
        })
        |> Repo.update()
        |> unwrap_insert()

      with %Assignment{} = assignment <-
             Repo.get_by(Assignment, assignment_id: session.assignment_id),
           true <- assignment.status in Assignment.active_statuses() do
        assignment =
          assignment
          |> Assignment.changeset(%{
            status: "expired",
            active_claim_key: nil,
            runner_id: "",
            session_id: "",
            summary: "runner session expired or runner stale",
            completed_at: now
          })
          |> Repo.update()
          |> unwrap_insert()

        _ = maybe_release_lease(assignment, assignment.claimant_agent_id)
        _ = record_assignment(assignment, "assignment.expired")
      end

      _ = record_runner_session(session, "runner_session.expired")
      session
    end)
    |> case do
      {:ok, session} -> session
      {:error, reason} -> reason
    end
  end

  defp runner_session_attrs(%Assignment{} = assignment, %Runner{} = runner, now, opts) do
    session_id = clean(Keyword.get(opts, :session_id, runner_session_id()))

    tmux_session_name =
      clean(Keyword.get(opts, :tmux_session_name, default_tmux_session(runner, assignment)))

    tmux_server = clean(Keyword.get(opts, :tmux_server, runner.tmux_server || "jx"))

    %{
      session_id: session_id,
      runner_id: runner.runner_id,
      agent_id: runner.agent_id,
      assignment_id: assignment.assignment_id,
      workspace_id: assignment.workspace_id,
      action_id: assignment.action_id,
      approval_id: assignment.approval_id,
      status: "created",
      active_assignment_key: runner_assignment_key(assignment.assignment_id),
      correlation_id: assignment.correlation_id,
      tmux_server: tmux_server,
      tmux_session_name: tmux_session_name,
      log_path: clean(Keyword.get(opts, :log_path, "")),
      last_summary: "runner session created",
      metadata:
        encode_json(%{
          host_name: runner.host_name,
          attach_command: "tmux -L #{tmux_server} attach -t #{tmux_session_name}",
          created_by: Keyword.get(opts, :created_by, "operator")
        }),
      started_at: now,
      heartbeat_at: now,
      expires_at: runner_session_expires_at(runner, now)
    }
  end

  defp active_runner_session_for_assignment(assignment_id) do
    RunnerSession
    |> where([session], session.active_assignment_key == ^runner_assignment_key(assignment_id))
    |> where([session], session.status in ^RunnerSession.active_statuses())
    |> order_by([session], desc: session.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  defp ensure_runner_live(%Runner{} = runner, now) do
    if stale_runner?(runner, now),
      do: {:error, {:runner_stale, runner.runner_id}},
      else: :ok
  end

  defp ensure_runner_capable(%Runner{} = runner, %Assignment{} = assignment) do
    capabilities = decode_json_list(runner.capabilities)
    required = decode_json_list(assignment.required_capabilities)
    affinity = decode_json_list(runner.workspace_affinity)
    routing = assignment_runner_requirements(assignment)
    metadata = decode_metadata(runner)
    active_sessions = routable_active_sessions_for_runner(runner, assignment)
    concurrency_limit = runner_concurrency_limit(metadata)

    cond do
      not Enum.all?(required, &(&1 in capabilities)) ->
        {:error, {:runner_missing_capabilities, required -- capabilities}}

      affinity != [] and assignment.workspace_id not in affinity ->
        {:error, {:runner_workspace_mismatch, assignment.workspace_id}}

      active_sessions >= concurrency_limit ->
        {:error, {:runner_concurrency_limit, concurrency_limit}}

      not routing_requirement_met?(routing, "host", runner.host_name) ->
        {:error, {:runner_host_mismatch, Map.get(routing, "host")}}

      not routing_requirement_met?(routing, "os", metadata_value(metadata, "os")) ->
        {:error, {:runner_os_mismatch, Map.get(routing, "os")}}

      not routing_requirement_met?(routing, "repo", metadata_value(metadata, "repo")) ->
        {:error, {:runner_repo_mismatch, Map.get(routing, "repo")}}

      not routing_requirement_met?(
        routing,
        "branch_isolation",
        metadata_value(metadata, "branch_isolation")
      ) ->
        {:error, {:runner_branch_isolation_mismatch, Map.get(routing, "branch_isolation")}}

      not routing_requirement_met?(routing, "runtime_id", metadata_value(metadata, "runtime_id")) ->
        {:error, {:runner_runtime_mismatch, Map.get(routing, "runtime_id")}}

      not routing_requirement_met?(
        routing,
        "runtime_path",
        metadata_value(metadata, "runtime_path")
      ) ->
        {:error, {:runner_runtime_path_mismatch, Map.get(routing, "runtime_path")}}

      not tools_requirement_met?(routing, metadata) ->
        {:error, {:runner_missing_tools, Map.get(routing, "tools", []) -- runner_tools(metadata)}}

      true ->
        :ok
    end
  end

  defp ensure_runner_owns_session(%Runner{runner_id: runner_id}, %RunnerSession{
         runner_id: runner_id
       }),
       do: :ok

  defp ensure_runner_owns_session(_runner, %RunnerSession{runner_id: owner}),
    do: {:error, {:runner_session_owned_by, owner}}

  defp ensure_runner_session_active(%RunnerSession{status: status})
       when status in ["completed", "failed", "expired", "ended"],
       do: {:error, {:runner_session_closed, status}}

  defp ensure_runner_session_active(%RunnerSession{}), do: :ok

  defp runner_summary(%Runner{} = runner, now) do
    %{
      runner_id: runner.runner_id,
      agent_id: runner.agent_id,
      host_name: runner.host_name,
      status: runner_status(runner, now),
      capabilities: decode_json_list(runner.capabilities),
      workspace_affinity: decode_json_list(runner.workspace_affinity),
      heartbeat_ttl_seconds: runner.heartbeat_ttl_seconds,
      last_heartbeat_at: runner.last_heartbeat_at,
      tmux_server: runner.tmux_server,
      tmux_session_prefix: runner.tmux_session_prefix,
      active_sessions: active_sessions_for_runner(runner.runner_id),
      stale: stale_runner?(runner, now)
    }
  end

  defp runner_session_summary(%RunnerSession{} = session, now) do
    %{
      session_id: session.session_id,
      runner_id: session.runner_id,
      agent_id: session.agent_id,
      assignment_id: session.assignment_id,
      workspace_id: session.workspace_id,
      action_id: session.action_id,
      approval_id: session.approval_id,
      status: runner_session_status(session, now),
      correlation_id: session.correlation_id,
      tmux_server: session.tmux_server,
      tmux_session_name: session.tmux_session_name,
      log_path: session.log_path,
      last_summary: session.last_summary,
      started_at: session.started_at,
      heartbeat_at: session.heartbeat_at,
      ended_at: session.ended_at,
      expires_at: session.expires_at,
      stale: runner_session_stale?(session, now),
      next: runner_session_next(session)
    }
  end

  defp do_execute_assignment(assignment_id, agent_id, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with %Assignment{} = assignment <- Repo.get_by(Assignment, assignment_id: assignment_id),
         %Agent{} = agent <- Repo.get_by(Agent, agent_id: clean(agent_id)),
         :ok <- ensure_agent_live(agent, now),
         :ok <- ensure_assignment_claimed_by(assignment, agent.agent_id),
         :ok <- ensure_assignment_executable(assignment) do
      case SafeActions.execute(assignment.action_id, safe_action_execute_opts(agent, opts)) do
        {:ok, result} ->
          complete_assignment(assignment, agent, result, now)

        {:error, reason} ->
          _ = mark_assignment_failed(assignment_id, agent_id, reason, now)
          {:error, reason}
      end
    else
      nil ->
        {:error, :assignment_or_agent_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_assignment(%Assignment{} = assignment, %Agent{} = agent, result, now) do
    Repo.transaction(fn ->
      assignment =
        assignment
        |> Assignment.changeset(%{
          status: "completed",
          active_claim_key: nil,
          summary: result.action.result_summary,
          last_report_at: now,
          completed_at: now
        })
        |> Repo.update()
        |> unwrap_insert()

      _ = maybe_release_lease(assignment, agent.agent_id)
      _ = update_agent_status(agent, "idle")

      _ =
        record_assignment(assignment, "assignment.completed",
          agent: agent,
          payload: %{result: safe_result(result)}
        )

      assignment
    end)
    |> unwrap_transaction()
  end

  defp update_claimed_assignment(assignment_id, agent_id, kind, opts, attrs_fun) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Repo.transaction(fn ->
      with %Assignment{} = assignment <- Repo.get_by(Assignment, assignment_id: assignment_id),
           %Agent{} = agent <- Repo.get_by(Agent, agent_id: clean(agent_id)),
           :ok <- ensure_agent_live(agent, now),
           :ok <- ensure_assignment_claimed_by(assignment, agent.agent_id) do
        attrs = attrs_fun.(assignment, now)

        assignment =
          assignment
          |> Assignment.changeset(attrs)
          |> Repo.update()
          |> unwrap_insert()

        _ =
          record_assignment(assignment, kind,
            agent: agent,
            payload: Keyword.get(opts, :payload, %{})
          )

        assignment
      else
        nil -> Repo.rollback(:assignment_or_agent_not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  defp mark_assignment_failed(assignment_id, agent_id, reason, now) do
    with %Assignment{} = assignment <- Repo.get_by(Assignment, assignment_id: assignment_id),
         %Agent{} = agent <- Repo.get_by(Agent, agent_id: clean(agent_id)) do
      assignment =
        assignment
        |> Assignment.changeset(%{
          status: "failed",
          active_claim_key: nil,
          summary: inspect(reason),
          last_report_at: now,
          completed_at: now
        })
        |> Repo.update!()

      _ = maybe_release_lease(assignment, agent.agent_id)
      _ = update_agent_status(agent, "idle")

      _ =
        record_assignment(assignment, "assignment.failed",
          agent: agent,
          payload: %{reason: inspect(reason)}
        )

      {:ok, assignment}
    end
  end

  defp expire_assignment(%Assignment{} = assignment, now) do
    assignment =
      assignment
      |> Assignment.changeset(%{
        status: "expired",
        active_claim_key: nil,
        summary: "assignment expired or claimant stale",
        completed_at: now
      })
      |> Repo.update!()

    _ = maybe_release_lease(assignment, assignment.claimant_agent_id)
    _ = record_assignment(assignment, "assignment.expired")
    assignment
  end

  defp fetch_safe_action(action_id) do
    case Repo.get_by(OrchestrationAction, action_id: action_id) do
      %OrchestrationAction{source: "approval"} = action ->
        {:ok, action}

      %OrchestrationAction{} = action ->
        {:error, {:unsupported_safe_action_source, action.source}}

      nil ->
        {:error, {:action_not_found, action_id}}
    end
  end

  defp ensure_devide_runner_assignable(
         %Assignment{safe_action_kind: "rerun_devide_command"} = assignment,
         %OrchestrationAction{action: "rerun_devide_command"} = action
       ) do
    with :ok <- ensure_assignable_action(action) do
      ensure_assignment_open(assignment)
    end
  end

  defp ensure_devide_runner_assignable(%Assignment{safe_action_kind: kind}, _action),
    do: {:error, {:unsupported_devide_runner_safe_action, kind}}

  defp validate_devide_runner_enqueue(
         %{body: body} = envelope,
         %Assignment{} = assignment,
         command_id
       )
       when is_map(body) do
    devide_assignment = field(body, "assignment") || %{}
    action = field(devide_assignment, "action") || %{}
    metadata = field(devide_assignment, "metadata") || %{}

    cond do
      field(body, "protocol") != "jx.runner.v1" ->
        {:error, {:malformed_devide_response, :protocol_mismatch}}

      text_field(devide_assignment, "id") == "" ->
        {:error, {:malformed_devide_response, :missing_assignment_id}}

      text_field(devide_assignment, "workspace_id") != assignment.workspace_id ->
        {:error, {:malformed_devide_response, :workspace_mismatch}}

      text_field(action, "command_id") != command_id ->
        {:error, {:malformed_devide_response, :command_mismatch}}

      text_field(metadata, "jx_assignment_id") != assignment.assignment_id ->
        {:error, {:malformed_devide_response, :jx_assignment_mismatch}}

      true ->
        {:ok, devide_assignment_with_envelope(devide_assignment, envelope)}
    end
  end

  defp validate_devide_runner_enqueue(_envelope, _assignment, _command_id),
    do: {:error, {:malformed_devide_response, :non_map_body}}

  defp devide_assignment_with_envelope(devide_assignment, envelope) do
    Map.put(devide_assignment, "_envelope", %{
      status: Map.get(envelope, :status),
      correlation_id: Map.get(envelope, :correlation_id, ""),
      headers: Map.get(envelope, :headers, %{})
    })
  end

  defp record_devide_runner_enqueued(
         %Assignment{} = assignment,
         envelope,
         devide_assignment,
         now
       ) do
    metadata =
      assignment
      |> decode_metadata()
      |> Map.put("devide_runner", %{
        "assignment_id" => text_field(devide_assignment, "id"),
        "status" => text_field(devide_assignment, "status"),
        "safe_action_id" => text_field(devide_assignment, "safe_action_id"),
        "queued_at" => text_field(devide_assignment, "queued_at"),
        "protocol" => "jx.runner.v1",
        "enqueued_at" => DateTime.to_iso8601(now)
      })

    Repo.transaction(fn ->
      assignment =
        assignment
        |> Assignment.changeset(%{
          summary: "DevIDE runner assignment #{text_field(devide_assignment, "id")} queued",
          last_report_at: now,
          metadata: encode_json(metadata)
        })
        |> Repo.update()
        |> unwrap_insert()

      _ =
        record_devide_runner_event_once(assignment, "devide_runner.assignment_enqueued", %{
          status: assignment.status,
          devide_assignment: devide_assignment,
          devide_response: envelope
        })

      assignment
    end)
    |> unwrap_transaction()
  end

  defp record_devide_runner_enqueue_failed(assignment_id, reason) do
    case Repo.get_by(Assignment, assignment_id: clean(assignment_id)) do
      %Assignment{} = assignment ->
        record_devide_runner_event_once(
          assignment,
          "devide_runner.assignment_enqueue_failed",
          %{
            status: assignment.status,
            failure_class: RunnerProtocol.failure_class(reason),
            reason: inspect(reason)
          },
          severity: "warning",
          summary:
            "DevIDE runner enqueue failed for #{assignment.assignment_id}: #{inspect(reason)}"
        )

      nil ->
        :ok
    end
  end

  defp validate_devide_runner_replay(replay, %Assignment{} = assignment) do
    RunnerProtocol.validate_replay(replay, %{
      assignment_id: assignment.assignment_id,
      workspace_id: assignment.workspace_id,
      action_id: assignment.action_id
    })
  end

  defp record_devide_runner_replay_mismatch(replay, opts, reason) do
    assignment_id =
      opts
      |> Keyword.get(:assignment_id)
      |> clean()

    case Repo.get_by(Assignment, assignment_id: assignment_id) do
      %Assignment{} = assignment ->
        record_devide_runner_event_once(
          assignment,
          "devide_runner.replay_mismatch",
          %{
            status: assignment.status,
            failure_class: "replay_mismatch",
            reason: inspect(reason),
            replay: replay
          },
          severity: "warning",
          summary:
            "DevIDE runner replay mismatch for #{assignment.assignment_id}: #{inspect(reason)}"
        )

      nil ->
        :ok
    end
  end

  defp devide_runner_reconciliation_targets(opts) do
    limit = Keyword.get(opts, :limit, 50)

    Assignment
    |> maybe_filter_workspace(Keyword.get(opts, :workspace_id))
    |> where(
      [assignment],
      assignment.status in ^Assignment.active_statuses() or assignment.status == "failed"
    )
    |> order_by([assignment], asc: assignment.updated_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.filter(&(assignment_runner_id(&1) != ""))
  end

  defp assignment_runner_id(%Assignment{} = assignment) do
    assignment
    |> decode_metadata()
    |> get_in(["devide_runner", "assignment_id"])
    |> clean()
  end

  defp assignment_runner_requirements(%Assignment{} = assignment) do
    assignment
    |> decode_metadata()
    |> Map.get("routing", %{})
    |> normalize_runner_requirements()
  end

  defp runner_requirements(opts) do
    opts
    |> Keyword.get(:runner_requirements, Keyword.get(opts, :routing, %{}))
    |> normalize_runner_requirements()
  end

  defp normalize_runner_requirements(requirements) when is_map(requirements) do
    %{
      "host" => clean(Map.get(requirements, :host) || Map.get(requirements, "host")),
      "os" => clean(Map.get(requirements, :os) || Map.get(requirements, "os")),
      "repo" => clean(Map.get(requirements, :repo) || Map.get(requirements, "repo")),
      "branch_isolation" =>
        clean(
          Map.get(requirements, :branch_isolation) || Map.get(requirements, "branch_isolation")
        ),
      "runtime_id" =>
        clean(Map.get(requirements, :runtime_id) || Map.get(requirements, "runtime_id")),
      "runtime_path" =>
        clean(Map.get(requirements, :runtime_path) || Map.get(requirements, "runtime_path")),
      "tools" =>
        string_list(Map.get(requirements, :tools) || Map.get(requirements, "tools") || [])
    }
    |> Enum.reject(fn {_key, value} -> value in ["", []] end)
    |> Map.new()
  end

  defp normalize_runner_requirements(_requirements), do: %{}

  defp routing_requirement_met?(routing, key, actual) do
    case Map.get(routing, key) do
      value when value in [nil, ""] -> true
      required -> clean(actual) == required
    end
  end

  defp tools_requirement_met?(routing, metadata) do
    required = Map.get(routing, "tools", [])
    available = runner_tools(metadata)

    Enum.all?(required, &(&1 in available))
  end

  defp runner_tools(metadata),
    do: string_list(Map.get(metadata, "tools") || Map.get(metadata, :tools))

  defp runner_concurrency_limit(metadata) do
    case Map.get(metadata, "concurrency_limit") || Map.get(metadata, :concurrency_limit) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} when int > 0 -> int
          _ -> 1
        end

      _ ->
        1
    end
  end

  defp metadata_value(metadata, key),
    do: Map.get(metadata, key) || Map.get(metadata, String.to_atom(key))

  defp replay_assignment(replay) do
    case field(replay, "assignment") do
      assignment when is_map(assignment) -> {:ok, assignment}
      _ -> {:error, :missing_replay_assignment}
    end
  end

  defp replay_reports(replay) do
    case field(replay, "reports") do
      reports when is_list(reports) -> Enum.filter(reports, &is_map/1)
      _ -> []
    end
  end

  defp replay_jx_assignment_id(devide_assignment, opts) do
    metadata = field(devide_assignment, "metadata") || %{}

    assignment_id =
      first_present([
        text_field(metadata, "jx_assignment_id"),
        clean(Keyword.get(opts, :assignment_id))
      ])

    if assignment_id == "",
      do: {:error, :missing_jx_assignment_id},
      else: {:ok, assignment_id}
  end

  defp reconciled_assignment_attrs(%Assignment{} = assignment, devide_assignment, now) do
    devide_status = text_field(devide_assignment, "status")
    evidence = field(devide_assignment, "evidence") || %{}
    failure_reason = text_field(devide_assignment, "failure_reason")
    completed_at = parse_time(text_field(devide_assignment, "completed_at")) || now

    metadata =
      assignment
      |> decode_metadata()
      |> Map.put("devide_runner", %{
        "assignment_id" => text_field(devide_assignment, "id"),
        "status" => devide_status,
        "safe_action_id" => text_field(devide_assignment, "safe_action_id"),
        "completed_at" => text_field(devide_assignment, "completed_at"),
        "failure_reason" => failure_reason,
        "failure_class" => RunnerProtocol.assignment_failure_class(devide_assignment),
        "evidence" => evidence,
        "reconciled_at" => DateTime.to_iso8601(now)
      })

    base = %{
      summary: devide_replay_summary(devide_assignment),
      last_report_at: now,
      metadata: encode_json(metadata)
    }

    case devide_status do
      "succeeded" ->
        Map.merge(base, %{status: "completed", active_claim_key: nil, completed_at: completed_at})

      "failed" ->
        Map.merge(base, %{status: "failed", active_claim_key: nil, completed_at: completed_at})

      "expired" ->
        Map.merge(base, %{status: "expired", active_claim_key: nil, completed_at: completed_at})

      "abandoned" ->
        Map.merge(base, %{status: "failed", active_claim_key: nil, completed_at: completed_at})

      _ ->
        base
    end
  end

  defp record_devide_runner_report_once(%Assignment{} = assignment, devide_assignment, report) do
    report_id =
      first_present([
        text_field(report, "id"),
        text_field(report, "client_report_id"),
        text_field(report, "position")
      ])

    event_id =
      [
        "devide-runner-report",
        assignment.assignment_id,
        text_field(devide_assignment, "id"),
        report_id
      ]
      |> Enum.join(":")

    OperationalEvents.record_once(%{
      event_id: event_id,
      source: "devide",
      kind: "devide_runner.report_reconciled",
      entity_type: "assignment",
      entity_id: assignment.assignment_id,
      workspace_id: assignment.workspace_id,
      approval_id: assignment.approval_id,
      action_id: assignment.action_id,
      owner: assignment.claimant_agent_id,
      correlation_id: assignment.correlation_id,
      severity: devide_report_severity(report),
      summary:
        "DevIDE runner report #{text_field(report, "event")} for #{assignment.assignment_id}",
      payload: %{
        status: assignment.status,
        failure_class: RunnerProtocol.report_failure_class(report),
        devide_assignment_id: text_field(devide_assignment, "id"),
        report: report
      }
    })
  end

  defp record_devide_runner_reconciled_once(
         %Assignment{} = assignment,
         devide_assignment,
         reports
       ) do
    kind =
      case assignment.status do
        "completed" -> "devide_runner.assignment_completed"
        "failed" -> "devide_runner.assignment_failed"
        "expired" -> "devide_runner.assignment_expired"
        _ -> "devide_runner.assignment_reconciled"
      end

    record_devide_runner_event_once(
      assignment,
      kind,
      %{
        status: assignment.status,
        failure_class: RunnerProtocol.assignment_failure_class(devide_assignment),
        devide_assignment: devide_assignment,
        reports_total: length(reports)
      },
      severity: if(assignment.status in ["failed", "expired"], do: "warning", else: "notice"),
      summary: devide_replay_summary(devide_assignment)
    )
  end

  defp record_devide_runner_event_once(%Assignment{} = assignment, kind, payload, opts \\ []) do
    devide_assignment =
      Map.get(payload, :devide_assignment) || Map.get(payload, "devide_assignment") || %{}

    event_id =
      [
        "devide-runner",
        kind,
        assignment.assignment_id,
        text_field(devide_assignment, "id")
      ]
      |> Enum.join(":")

    OperationalEvents.record_once(%{
      event_id: event_id,
      source: "devide",
      kind: kind,
      entity_type: "assignment",
      entity_id: assignment.assignment_id,
      workspace_id: assignment.workspace_id,
      approval_id: assignment.approval_id,
      action_id: assignment.action_id,
      owner: assignment.claimant_agent_id,
      correlation_id: assignment.correlation_id,
      severity: Keyword.get(opts, :severity, "notice"),
      summary:
        Keyword.get(opts, :summary) ||
          "DevIDE runner #{kind} for #{assignment.assignment_id}",
      payload: payload
    })
  end

  defp devide_replay_summary(devide_assignment) do
    id = text_field(devide_assignment, "id")
    status = text_field(devide_assignment, "status")
    reason = text_field(devide_assignment, "failure_reason")

    case {status, reason} do
      {"failed", reason} when reason != "" -> "DevIDE runner assignment #{id} failed: #{reason}"
      _ -> "DevIDE runner assignment #{id} #{status}"
    end
  end

  defp devide_report_severity(report) do
    if text_field(report, "event") == "failed", do: "warning", else: "notice"
  end

  defp ensure_assignable_action(%OrchestrationAction{status: status})
       when status not in ["planned", "queued"],
       do: {:error, {:action_not_assignable, status}}

  defp ensure_assignable_action(%OrchestrationAction{}), do: :ok

  defp ensure_assignment_open(%Assignment{status: status})
       when status in ["completed", "failed", "expired"],
       do: {:error, {:assignment_closed, status}}

  defp ensure_assignment_open(%Assignment{}), do: :ok

  defp ensure_assignment_executable(%Assignment{status: status})
       when status in ["claimed", "started", "progressed"],
       do: :ok

  defp ensure_assignment_executable(%Assignment{status: status}),
    do: {:error, {:assignment_not_executable, status}}

  defp ensure_assignment_claimed_by(%Assignment{claimant_agent_id: agent_id}, agent_id)
       when agent_id not in [nil, ""],
       do: :ok

  defp ensure_assignment_claimed_by(%Assignment{claimant_agent_id: other}, _agent_id),
    do: {:error, {:assignment_claimed_by, other}}

  defp ensure_agent_live(%Agent{} = agent, now) do
    if stale_agent?(agent, now),
      do: {:error, {:agent_stale, agent.agent_id}},
      else: :ok
  end

  defp ensure_agent_capable(%Agent{} = agent, %Assignment{} = assignment) do
    capabilities = decode_json_list(agent.capabilities)
    required = decode_json_list(assignment.required_capabilities)
    affinity = decode_json_list(agent.workspace_affinity)

    cond do
      not Enum.all?(required, &(&1 in capabilities)) ->
        {:error, {:agent_missing_capabilities, required -- capabilities}}

      affinity != [] and assignment.workspace_id not in affinity ->
        {:error, {:agent_workspace_mismatch, assignment.workspace_id}}

      true ->
        :ok
    end
  end

  defp ensure_action_lease(%Assignment{} = assignment, %Agent{} = agent, now, opts) do
    case OperationalLeases.active("action", assignment.action_id, now: now) do
      %Lease{owner: owner} = lease when owner == agent.agent_id ->
        {:ok, lease}

      %Lease{} = lease ->
        {:error, {:lease_conflict, lease}}

      nil ->
        OperationalLeases.acquire("action", assignment.action_id, agent.agent_id,
          now: now,
          ttl_seconds: Keyword.get(opts, :ttl_seconds, @default_assignment_ttl_seconds),
          correlation_id: assignment.correlation_id,
          metadata: %{
            workspace_id: assignment.workspace_id,
            approval_id: assignment.approval_id,
            assignment_id: assignment.assignment_id
          }
        )
    end
  end

  defp active_assignment_for_action(action_id) do
    Assignment
    |> where([assignment], assignment.action_id == ^action_id)
    |> where([assignment], assignment.status in ^Assignment.active_statuses())
    |> order_by([assignment], desc: assignment.id)
    |> limit(1)
    |> Repo.one()
  end

  defp maybe_release_lease(%Assignment{lease_id: ""}, _owner), do: :ok
  defp maybe_release_lease(%Assignment{lease_id: nil}, _owner), do: :ok

  defp maybe_release_lease(%Assignment{lease_id: lease_id}, _owner) do
    case Repo.get_by(Lease, lease_id: lease_id) do
      %Lease{status: "active"} = lease ->
        released =
          lease
          |> Lease.changeset(%{
            status: "released",
            active_key: nil,
            released_at: DateTime.utc_now()
          })
          |> Repo.update!()

        _ = OperationalEvents.record_lease(released, "lease.released")
        :ok

      _other ->
        :ok
    end
  end

  defp record_agent(%Agent{} = agent, kind) do
    payload = %{
      agent_id: agent.agent_id,
      name: agent.name,
      status: agent.status,
      capabilities: decode_json_list(agent.capabilities),
      workspace_affinity: decode_json_list(agent.workspace_affinity),
      heartbeat_ttl_seconds: agent.heartbeat_ttl_seconds,
      last_heartbeat_at: agent.last_heartbeat_at
    }

    _ = record_report(nil, agent, kind, payload)

    OperationalEvents.record(%{
      source: "delegated_execution",
      kind: kind,
      entity_type: "agent",
      entity_id: agent.agent_id,
      owner: agent.agent_id,
      severity: "notice",
      summary: "agent #{agent.agent_id} #{kind}",
      payload: payload
    })
  end

  defp record_runner(%Runner{} = runner, kind) do
    payload = runner_payload(runner)

    _ = record_runner_report(nil, runner, kind, payload)

    OperationalEvents.record(%{
      source: "delegated_execution",
      kind: kind,
      entity_type: "runner",
      entity_id: runner.runner_id,
      owner: runner.runner_id,
      severity: "notice",
      summary: "runner #{runner.runner_id} #{kind}",
      payload: payload
    })
  end

  defp record_runner_session(%RunnerSession{} = session, kind, opts \\ []) do
    payload = Map.merge(runner_session_payload(session), Keyword.get(opts, :payload, %{}))

    _ = record_runner_report(session, nil, kind, payload)

    OperationalEvents.record(%{
      source: "delegated_execution",
      kind: kind,
      entity_type: "runner_session",
      entity_id: session.session_id,
      workspace_id: session.workspace_id,
      approval_id: session.approval_id,
      action_id: session.action_id,
      owner: session.runner_id,
      correlation_id: session.correlation_id,
      severity: runner_session_severity(kind),
      summary: "runner session #{session.session_id} #{session.status}",
      payload: payload
    })
  end

  defp record_assignment(%Assignment{} = assignment, kind, opts \\ []) do
    agent = Keyword.get(opts, :agent)
    payload = Map.merge(assignment_payload(assignment), Keyword.get(opts, :payload, %{}))

    _ = record_report(assignment, agent, kind, payload)

    OperationalEvents.record(%{
      source: "delegated_execution",
      kind: kind,
      entity_type: "assignment",
      entity_id: assignment.assignment_id,
      workspace_id: assignment.workspace_id,
      approval_id: assignment.approval_id,
      action_id: assignment.action_id,
      owner: assignment.claimant_agent_id,
      correlation_id: assignment.correlation_id,
      severity: assignment_severity(kind),
      summary: "assignment #{assignment.assignment_id} #{assignment.status}",
      payload: payload
    })
  end

  defp record_report(assignment, agent, kind, payload) do
    attrs = report_attrs(assignment, agent, kind, payload)

    %Report{}
    |> Report.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, report} ->
        {:ok, report}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :fingerprint) do
          {:ok, Repo.get_by!(Report, fingerprint: attrs.fingerprint)}
        else
          {:error, changeset}
        end
    end
  end

  defp record_runner_report(session, runner, kind, payload) do
    attrs = runner_report_attrs(session, runner, kind, payload)

    %RunnerReport{}
    |> RunnerReport.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, report} ->
        {:ok, report}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :fingerprint) do
          {:ok, Repo.get_by!(RunnerReport, fingerprint: attrs.fingerprint)}
        else
          {:error, changeset}
        end
    end
  end

  defp report_attrs(nil, %Agent{} = agent, kind, payload) do
    attrs = %{
      report_id: report_id(),
      assignment_id: "",
      agent_id: agent.agent_id,
      action_id: "",
      workspace_id: "",
      kind: kind,
      status: agent.status,
      correlation_id: text_field(payload, "correlation_id") || OperationalEvents.correlation_id(),
      summary: "agent #{agent.agent_id} #{kind}",
      payload: encode_json(payload)
    }

    Map.put(attrs, :fingerprint, report_fingerprint(attrs))
  end

  defp report_attrs(%Assignment{} = assignment, agent, kind, payload) do
    attrs = %{
      report_id: report_id(),
      assignment_id: assignment.assignment_id,
      agent_id: report_agent_id(assignment, agent),
      action_id: assignment.action_id,
      workspace_id: assignment.workspace_id,
      kind: kind,
      status: assignment.status,
      correlation_id: assignment.correlation_id,
      summary: assignment.summary,
      payload: encode_json(payload)
    }

    Map.put(attrs, :fingerprint, report_fingerprint(attrs))
  end

  defp runner_report_attrs(nil, %Runner{} = runner, kind, payload) do
    attrs = %{
      report_id: runner_report_id(),
      session_id: "",
      runner_id: runner.runner_id,
      agent_id: runner.agent_id,
      assignment_id: "",
      workspace_id: "",
      action_id: "",
      kind: kind,
      status: runner.status,
      correlation_id: text_field(payload, "correlation_id") || OperationalEvents.correlation_id(),
      summary: "runner #{runner.runner_id} #{kind}",
      payload: encode_json(payload)
    }

    Map.put(attrs, :fingerprint, runner_report_fingerprint(attrs))
  end

  defp runner_report_attrs(%RunnerSession{} = session, _runner, kind, payload) do
    attrs = %{
      report_id: runner_report_id(),
      session_id: session.session_id,
      runner_id: session.runner_id,
      agent_id: session.agent_id,
      assignment_id: session.assignment_id,
      workspace_id: session.workspace_id,
      action_id: session.action_id,
      kind: kind,
      status: session.status,
      correlation_id: session.correlation_id,
      summary: session.last_summary,
      payload: encode_json(payload)
    }

    Map.put(attrs, :fingerprint, runner_report_fingerprint(attrs))
  end

  defp runner_payload(%Runner{} = runner) do
    %{
      runner_id: runner.runner_id,
      agent_id: runner.agent_id,
      host_name: runner.host_name,
      status: runner.status,
      capabilities: decode_json_list(runner.capabilities),
      workspace_affinity: decode_json_list(runner.workspace_affinity),
      heartbeat_ttl_seconds: runner.heartbeat_ttl_seconds,
      last_heartbeat_at: runner.last_heartbeat_at,
      tmux_server: runner.tmux_server,
      tmux_session_prefix: runner.tmux_session_prefix,
      metadata: decode_metadata(runner)
    }
  end

  defp runner_session_payload(%RunnerSession{} = session) do
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
      metadata: decode_metadata(session),
      started_at: session.started_at,
      heartbeat_at: session.heartbeat_at,
      ended_at: session.ended_at,
      expires_at: session.expires_at
    }
  end

  defp assignment_payload(%Assignment{} = assignment) do
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
      routing: assignment_runner_requirements(assignment),
      summary: assignment.summary,
      claimed_at: assignment.claimed_at,
      started_at: assignment.started_at,
      last_report_at: assignment.last_report_at,
      completed_at: assignment.completed_at,
      expires_at: assignment.expires_at
    }
  end

  defp report_agent_id(_assignment, %Agent{agent_id: agent_id}), do: agent_id

  defp report_agent_id(%Assignment{claimant_agent_id: agent_id}, _agent)
       when agent_id not in [nil, ""], do: agent_id

  defp report_agent_id(_assignment, _agent), do: "unassigned"

  defp assignment_summary(%Assignment{} = assignment, now) do
    %{
      assignment_id: assignment.assignment_id,
      action_id: assignment.action_id,
      approval_id: assignment.approval_id,
      workspace_id: assignment.workspace_id,
      safe_action_kind: assignment.safe_action_kind,
      status: assignment_status(assignment, now),
      claimant_agent_id: assignment.claimant_agent_id,
      runner_id: assignment.runner_id,
      session_id: assignment.session_id,
      lease_id: assignment.lease_id,
      correlation_id: assignment.correlation_id,
      required_capabilities: decode_json_list(assignment.required_capabilities),
      routing: assignment_runner_requirements(assignment),
      summary: assignment.summary,
      stale: assignment_stale?(assignment, now),
      next: assignment_next(assignment)
    }
  end

  defp agent_summary(%Agent{} = agent, now) do
    %{
      agent_id: agent.agent_id,
      name: agent.name,
      status: agent_status(agent, now),
      capabilities: decode_json_list(agent.capabilities),
      workspace_affinity: decode_json_list(agent.workspace_affinity),
      heartbeat_ttl_seconds: agent.heartbeat_ttl_seconds,
      last_heartbeat_at: agent.last_heartbeat_at,
      active_assignments: active_assignments_for_agent(agent.agent_id),
      stale: stale_agent?(agent, now)
    }
  end

  defp active_assignments_for_agent(agent_id) do
    Assignment
    |> where([assignment], assignment.claimant_agent_id == ^agent_id)
    |> where([assignment], assignment.status in ^Assignment.active_statuses())
    |> Repo.aggregate(:count)
  end

  defp active_sessions_for_runner(runner_id) do
    RunnerSession
    |> where([session], session.runner_id == ^runner_id)
    |> where([session], session.status in ^RunnerSession.active_statuses())
    |> Repo.aggregate(:count)
  end

  defp routable_active_sessions_for_runner(%Runner{} = runner, %Assignment{} = assignment) do
    active = active_sessions_for_runner(runner.runner_id)

    case active_runner_session_for_assignment(assignment.assignment_id) do
      %RunnerSession{runner_id: runner_id} when runner_id == runner.runner_id ->
        max(active - 1, 0)

      _other ->
        active
    end
  end

  defp assignment_next(%Assignment{status: "created", assignment_id: id}),
    do: "jx assignments claim #{id} --runner <runner-id>"

  defp assignment_next(%Assignment{session_id: session_id})
       when session_id not in [nil, ""],
       do: "jx sessions show #{session_id}"

  defp assignment_next(%Assignment{status: status, assignment_id: id})
       when status in ["claimed", "started", "progressed"],
       do: "jx assignments execute #{id} --agent <agent-id> --confirm"

  defp assignment_next(%Assignment{assignment_id: id}), do: "jx timeline assignment #{id}"

  defp assignment_status(%Assignment{} = assignment, now) do
    if assignment_stale?(assignment, now), do: "expired", else: assignment.status
  end

  defp assignment_stale?(%Assignment{status: status}, _now)
       when status in ["completed", "failed", "expired"],
       do: false

  defp assignment_stale?(%Assignment{expires_at: nil}, _now), do: false

  defp assignment_stale?(%Assignment{expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt

  defp agent_status(%Agent{} = agent, now) do
    cond do
      agent.status == "disabled" -> "disabled"
      stale_agent?(agent, now) -> "stale"
      active_assignments_for_agent(agent.agent_id) > 0 -> "busy"
      true -> "idle"
    end
  end

  defp heartbeat_status(%Agent{status: "disabled"}), do: "disabled"

  defp heartbeat_status(%Agent{} = agent) do
    if active_assignments_for_agent(agent.agent_id) > 0, do: "busy", else: "idle"
  end

  defp runner_status(%Runner{} = runner, now) do
    cond do
      runner.status == "disabled" -> "disabled"
      stale_runner?(runner, now) -> "stale"
      active_sessions_for_runner(runner.runner_id) > 0 -> "busy"
      true -> "idle"
    end
  end

  defp runner_heartbeat_status(%Runner{status: "disabled"}), do: "disabled"

  defp runner_heartbeat_status(%Runner{} = runner),
    do: if(active_sessions_for_runner(runner.runner_id) > 0, do: "busy", else: "idle")

  defp runner_agent_status(%Runner{} = runner, now) do
    cond do
      runner.status == "disabled" -> "disabled"
      stale_runner?(runner, now) -> "stale"
      true -> "idle"
    end
  end

  defp runner_status_after_session(%RunnerSession{status: status})
       when status in ["completed", "failed", "expired", "ended"],
       do: "idle"

  defp runner_status_after_session(_session), do: "busy"

  defp runner_session_status(%RunnerSession{} = session, now) do
    if runner_session_stale?(session, now), do: "stale", else: session.status
  end

  defp runner_session_stale?(%RunnerSession{status: status}, _now)
       when status in ["completed", "failed", "expired", "ended"],
       do: false

  defp runner_session_stale?(%RunnerSession{expires_at: nil}, _now), do: false

  defp runner_session_stale?(%RunnerSession{expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt

  defp runner_session_next(%RunnerSession{status: status, session_id: id})
       when status in ["claimed", "running", "progressed", "stale"],
       do: "jx sessions show #{id}"

  defp runner_session_next(%RunnerSession{session_id: id}), do: "jx timeline session #{id}"

  defp update_agent_status(%Agent{} = agent, status) do
    agent
    |> Agent.changeset(%{status: status})
    |> Repo.update()
  end

  defp update_runner_status(%Runner{} = runner, status) do
    runner
    |> Runner.changeset(%{status: status})
    |> Repo.update()
  end

  defp stale_agent?(%Agent{last_heartbeat_at: nil}, _now), do: true

  defp stale_agent?(%Agent{} = agent, now) do
    DateTime.diff(now, agent.last_heartbeat_at, :second) > agent.heartbeat_ttl_seconds
  end

  defp stale_runner?(%Runner{last_heartbeat_at: nil}, _now), do: true

  defp stale_runner?(%Runner{} = runner, now) do
    DateTime.diff(now, runner.last_heartbeat_at, :second) > runner.heartbeat_ttl_seconds
  end

  defp maybe_filter_agent_status(query, nil), do: query
  defp maybe_filter_agent_status(query, "all"), do: query
  defp maybe_filter_agent_status(query, "stale"), do: query

  defp maybe_filter_agent_status(query, status),
    do: where(query, [agent], agent.status == ^status)

  defp maybe_filter_runner_status(query, nil), do: query
  defp maybe_filter_runner_status(query, "all"), do: query
  defp maybe_filter_runner_status(query, "stale"), do: query

  defp maybe_filter_runner_status(query, status),
    do: where(query, [runner], runner.status == ^status)

  defp maybe_filter_summary_status(summaries, nil), do: summaries
  defp maybe_filter_summary_status(summaries, "all"), do: summaries

  defp maybe_filter_summary_status(summaries, status),
    do: Enum.filter(summaries, &(&1.status == status))

  defp maybe_filter_assignment_status(query, nil),
    do: where(query, [assignment], assignment.status in ^Assignment.active_statuses())

  defp maybe_filter_assignment_status(query, "active"),
    do: where(query, [assignment], assignment.status in ^Assignment.active_statuses())

  defp maybe_filter_assignment_status(query, "all"), do: query

  defp maybe_filter_assignment_status(query, status),
    do: where(query, [assignment], assignment.status == ^status)

  defp maybe_filter_assignment_agent(query, nil), do: query

  defp maybe_filter_assignment_agent(query, agent_id),
    do: where(query, [assignment], assignment.claimant_agent_id == ^agent_id)

  defp maybe_filter_workspace(query, nil), do: query

  defp maybe_filter_workspace(query, workspace_id),
    do: where(query, [assignment], assignment.workspace_id == ^workspace_id)

  defp maybe_filter_runner_session_status(query, nil),
    do: where(query, [session], session.status in ^RunnerSession.active_statuses())

  defp maybe_filter_runner_session_status(query, "active"),
    do: where(query, [session], session.status in ^RunnerSession.active_statuses())

  defp maybe_filter_runner_session_status(query, "all"), do: query

  defp maybe_filter_runner_session_status(query, status),
    do: where(query, [session], session.status == ^status)

  defp maybe_filter_runner_session_runner(query, nil), do: query

  defp maybe_filter_runner_session_runner(query, runner_id),
    do: where(query, [session], session.runner_id == ^runner_id)

  defp maybe_filter_runner_session_workspace(query, nil), do: query

  defp maybe_filter_runner_session_workspace(query, workspace_id),
    do: where(query, [session], session.workspace_id == ^workspace_id)

  defp maybe_filter_runner_session_assignment(query, nil), do: query

  defp maybe_filter_runner_session_assignment(query, assignment_id),
    do: where(query, [session], session.assignment_id == ^assignment_id)

  defp active_claim_key(assignment_id), do: "assignment:#{assignment_id}"
  defp runner_assignment_key(assignment_id), do: "runner-assignment:#{assignment_id}"

  defp runner_session_expires_at(%Runner{} = runner, now) do
    DateTime.add(now, runner.heartbeat_ttl_seconds, :second)
  end

  defp default_tmux_session(%Runner{} = runner, %Assignment{} = assignment) do
    prefix =
      if runner.tmux_session_prefix in [nil, ""],
        do: "jx-#{runner.runner_id}",
        else: runner.tmux_session_prefix

    "#{prefix}-#{assignment.assignment_id}"
  end

  defp merged_session_metadata(%RunnerSession{} = session, opts) do
    session
    |> decode_metadata()
    |> Map.merge(Map.new(Keyword.get(opts, :metadata, %{})))
    |> encode_json()
  end

  defp required_capabilities(%OrchestrationAction{} = action),
    do: ["safe_action:#{action.action}"]

  defp safe_action_execute_opts(%Agent{} = agent, opts) do
    [confirm: true, owner: agent.agent_id]
    |> maybe_keyword_put(:client, Keyword.get(opts, :client))
  end

  defp maybe_keyword_put(opts, _key, nil), do: opts
  defp maybe_keyword_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp safe_result(result) when is_map(result) do
    %{
      action_id: result.action.action_id,
      status: result.action.status,
      outcome: result.action.outcome,
      run: Map.get(result, :run),
      executed: Map.get(result, :executed)
    }
  end

  defp assignment_severity("assignment.failed"), do: "warning"
  defp assignment_severity("assignment.expired"), do: "warning"
  defp assignment_severity(_kind), do: "notice"

  defp runner_session_severity("runner_session.failed"), do: "warning"
  defp runner_session_severity("runner_session.expired"), do: "warning"
  defp runner_session_severity(_kind), do: "notice"

  defp report_fingerprint(attrs) do
    [
      attrs.assignment_id,
      attrs.agent_id,
      attrs.kind,
      attrs.status,
      attrs.correlation_id,
      attrs.payload
    ]
    |> Enum.join("|")
    |> fingerprint("drep")
  end

  defp runner_report_fingerprint(attrs) do
    [
      attrs.session_id,
      attrs.runner_id,
      attrs.kind,
      attrs.status,
      attrs.correlation_id,
      attrs.payload
    ]
    |> Enum.join("|")
    |> fingerprint("rrep")
  end

  defp agent_id do
    @agent_prefix <> random_hex(5)
  end

  defp runner_id do
    @runner_prefix <> random_hex(5)
  end

  defp assignment_id do
    @assignment_prefix <> random_hex(5)
  end

  defp runner_session_id do
    @runner_session_prefix <> random_hex(5)
  end

  defp report_id do
    @report_prefix <> random_hex(5)
  end

  defp runner_report_id do
    @runner_report_prefix <> random_hex(5)
  end

  defp random_hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp fingerprint(parts, prefix) do
    digest =
      parts
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}-#{digest}"
  end

  defp unwrap_insert({:ok, value}), do: value
  defp unwrap_insert({:error, changeset}), do: Repo.rollback(changeset)

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp encode_json_field(attrs, key, fallback) do
    value = Map.get(attrs, key, fallback)
    Map.put(attrs, key, encode_json(value))
  end

  defp maybe_encode_json_field(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> Map.put(attrs, key, encode_json(value))
      :error -> attrs
    end
  end

  defp encode_json(value) when is_binary(value), do: value
  defp encode_json(value), do: value |> normalize_payload() |> Jason.encode!()

  defp normalize_payload(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_payload(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_payload(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_payload(%Time{} = value), do: Time.to_iso8601(value)

  defp normalize_payload(%{} = map),
    do: Map.new(map, fn {key, value} -> {key, normalize_payload(value)} end)

  defp normalize_payload(values) when is_list(values), do: Enum.map(values, &normalize_payload/1)
  defp normalize_payload(value), do: value

  defp decode_json_list(text) do
    case Jason.decode(text || "[]") do
      {:ok, values} when is_list(values) -> Enum.map(values, &to_string/1)
      _other -> []
    end
  end

  defp string_list(values) when is_list(values) do
    values
    |> Enum.map(&clean/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp string_list(_values), do: []

  defp decode_metadata(%{metadata: metadata}) do
    case Jason.decode(metadata || "{}") do
      {:ok, values} when is_map(values) -> values
      _other -> %{}
    end
  end

  defp clean(nil), do: ""
  defp clean(value), do: value |> to_string() |> String.trim()

  defp text_field(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when value in [nil, ""] -> ""
      value -> to_string(value)
    end
  end

  defp text_field(_map, _key), do: ""

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp field(_map, _key), do: nil

  defp first_present(values) do
    Enum.find(values, "", fn value -> value not in [nil, ""] end)
  end

  defp parse_time(""), do: nil

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_time(_value), do: nil

  defp shell_quote(value) do
    value = to_string(value || "")

    if Regex.match?(~r{^[A-Za-z0-9_@%+=:,./-]+$}, value) do
      value
    else
      "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
    end
  end
end
