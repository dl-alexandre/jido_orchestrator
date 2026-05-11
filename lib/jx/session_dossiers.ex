defmodule JX.SessionDossiers do
  @moduledoc """
  Builds compact, agent-oriented dossiers for currently discovered sessions.

  Dossiers are computed from the live work board plus the existing observation
  and directive journals. They avoid becoming another source of truth.
  """

  @next_actions ~w(
    adopt
    blocked-profile
    capture
    capture-first
    draft-profile
    inspect
    mark-managed
    none
    observe
    resume-adopt
    resolve-repo-blocker
    send-session
    stream-adopt
  )

  @queue_order [
    "resolve-repo-blocker",
    "blocked-profile",
    "draft-profile",
    "send-session",
    "capture-first",
    "capture",
    "mark-managed",
    "resume-adopt",
    "stream-adopt",
    "adopt",
    "observe",
    "inspect",
    "none"
  ]

  def next_actions, do: @next_actions

  def queues(dossiers, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    dossiers
    |> Enum.group_by(&next_action_name/1)
    |> Enum.map(fn {action, grouped_dossiers} ->
      queue(action, grouped_dossiers, limit)
    end)
    |> Enum.sort_by(&queue_sort_key/1)
  end

  def build(items, changes, directives) do
    changes_by_ref = Map.new(changes, &{&1.ref, &1})

    Enum.map(items, fn item ->
      change = Map.get(changes_by_ref, item.ref)
      directive = latest_directive(item, directives)
      repo = repo_summary(item.git)

      %{
        ref: item.ref,
        host: item.host,
        type: item.type,
        kind: item.kind,
        process_role: Map.get(item, :process_role, ""),
        resume_available: Map.get(item, :resume_available, false),
        resume_ref: Map.get(item, :resume_ref, ""),
        zed_workspace: Map.get(item, :zed_workspace, ""),
        agent_name: item.agent_name,
        task_id: item.task_id,
        project: item.project,
        control_mode: item.control_mode,
        control_project: item.control_project,
        can_direct: item.can_direct,
        allowed_action: item.allowed_action,
        reason: item.reason,
        work_state: item.work_state,
        capture_status: item.capture_status,
        task: item.task,
        summary: item.summary,
        current_path: item.current_path,
        title: item.title,
        ssh_target: item.ssh_target,
        tmux_server: item.tmux_server,
        session_name: item.session_name,
        window: item.window,
        pane_index: item.pane_index,
        pane: item.pane,
        repo: repo,
        change: change_summary(change),
        last_directive: directive_summary(directive),
        directive_state: directive_state(directive, change),
        next_action: next_action(item, change, repo),
        handoff: handoff(item, change, directive, repo)
      }
    end)
  end

  defp queue(action, dossiers, limit) do
    %{
      action: action,
      total: length(dossiers),
      by_safety: count_by(dossiers, [:next_action, :safety]),
      by_priority: count_by(dossiers, [:next_action, :priority]),
      by_control: count_by(dossiers, [:control_mode]),
      by_type: count_by(dossiers, [:type]),
      by_kind: count_by(dossiers, [:kind]),
      by_process_role: count_by(dossiers, [:process_role]),
      items: dossiers |> Enum.take(limit) |> Enum.map(&queue_item/1)
    }
  end

  defp queue_item(dossier) do
    %{
      ref: dossier.ref,
      host: dossier.host,
      control_mode: dossier.control_mode,
      type: dossier.type,
      kind: dossier.kind,
      process_role: dossier.process_role,
      resume_available: dossier.resume_available,
      resume_ref: dossier.resume_ref,
      zed_workspace: dossier.zed_workspace,
      work_state: dossier.work_state,
      project: dossier.project,
      pane: dossier.pane,
      current_path: dossier.current_path,
      task: dossier.task,
      reason: dossier.next_action.reason,
      repo: %{
        branch: dossier.repo.branch,
        blockers: dossier.repo.blockers,
        risks: dossier.repo.risks
      }
    }
  end

  defp next_action_name(%{next_action: %{action: action}}), do: action
  defp next_action_name(_dossier), do: "unknown"

  defp queue_sort_key(%{action: action, total: total}) do
    {Enum.find_index(@queue_order, &(&1 == action)) || length(@queue_order), -total, action}
  end

  defp count_by(dossiers, path) do
    dossiers
    |> Enum.map(&get_in(&1, path))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
  end

  defp latest_directive(item, directives) do
    Enum.find(directives, &directive_matches?(&1, item))
  end

  defp directive_matches?(directive, item) do
    directive_task_match?(directive, item) or directive_pane_match?(directive, item)
  end

  defp directive_task_match?(directive, %{task_id: task_id})
       when is_binary(task_id) and task_id != "" do
    directive.task_ref == task_id
  end

  defp directive_task_match?(_directive, _item), do: false

  defp directive_pane_match?(directive, item) do
    directive.host &&
      directive.host.name == item.host &&
      directive.tmux_server == item.tmux_server &&
      directive.session_name == item.session_name &&
      directive.window == item.window &&
      directive.pane == item.pane_index
  end

  defp repo_summary(nil) do
    %{
      present: false,
      root: "",
      branch: "",
      upstream: "",
      dirty: false,
      changes: 0,
      untracked: 0,
      ahead: 0,
      behind: 0,
      submodules: "",
      blockers: [],
      risks: []
    }
  end

  defp repo_summary(git) do
    %{
      present: Map.get(git, :present, true),
      root: Map.get(git, :root, ""),
      branch: Map.get(git, :branch, ""),
      upstream: Map.get(git, :upstream, ""),
      dirty: Map.get(git, :dirty, false),
      changes: Map.get(git, :changes, 0),
      untracked: Map.get(git, :untracked, 0),
      ahead: Map.get(git, :ahead, 0),
      behind: Map.get(git, :behind, 0),
      submodules: Map.get(git, :submodules, ""),
      submodule_error: Map.get(git, :submodule_error, ""),
      blockers: repo_blockers(git),
      risks: repo_risks(git)
    }
  end

  defp repo_blockers(git) do
    case Map.get(git, :submodules) do
      "ok" -> []
      "" -> []
      nil -> []
      status -> ["submodules:#{status}"]
    end
  end

  defp repo_risks(git) do
    []
    |> maybe_risk(Map.get(git, :ahead, 0) > 0, "ahead:#{Map.get(git, :ahead, 0)}")
    |> maybe_risk(Map.get(git, :behind, 0) > 0, "behind:#{Map.get(git, :behind, 0)}")
    |> maybe_risk(Map.get(git, :dirty, false), "dirty:#{Map.get(git, :changes, 0)}")
    |> maybe_risk(Map.get(git, :remote_unverified, false), "remote-unverified")
  end

  defp maybe_risk(risks, true, risk), do: [risk | risks]
  defp maybe_risk(risks, false, _risk), do: risks

  defp change_summary(nil), do: nil

  defp change_summary(change) do
    %{
      change: change.change,
      needs_attention: change.needs_attention,
      work_state: change.work_state,
      previous_work_state: change.previous_work_state,
      capture_status: change.capture_status,
      previous_capture_status: change.previous_capture_status,
      changed_fields: change.changed_fields,
      observed_at: format_time(change.observed_at),
      elapsed_seconds: change.elapsed_seconds
    }
  end

  defp directive_summary(nil), do: nil

  defp directive_summary(directive) do
    %{
      directive_id: directive.directive_id,
      target_type: directive.target_type,
      task_ref: directive.task_ref,
      tmux_server: directive.tmux_server,
      session_name: directive.session_name,
      window: directive.window,
      pane: directive.pane,
      status: directive.status,
      enter: directive.enter,
      message: directive.message,
      error: directive.error,
      sent_at: format_time(directive.inserted_at)
    }
  end

  defp directive_state(nil, _change), do: "none"
  defp directive_state(%{status: "error"}, _change), do: "error"
  defp directive_state(_directive, nil), do: "sent-awaiting-observation"

  defp directive_state(directive, change) do
    case DateTime.compare(change.observed_at, directive.inserted_at) do
      :lt -> "sent-awaiting-observation"
      _other -> "observed-after-send"
    end
  end

  defp next_action(_item, _change, %{blockers: blockers}) when blockers != [] do
    %{
      action: "resolve-repo-blocker",
      priority: "high",
      safety: "manual",
      reason: Enum.join(blockers, ",")
    }
  end

  defp next_action(%{can_direct: true} = item, %{needs_attention: true}, _repo) do
    %{
      action: "send-session",
      priority: "high",
      safety: "gated",
      reason: "managed attention session can receive direction"
    }
    |> maybe_put_reason(item.reason)
  end

  defp next_action(item, %{needs_attention: true}, _repo) do
    %{
      action: item.allowed_action,
      priority: "high",
      safety: action_safety(item.allowed_action),
      reason: item.reason
    }
  end

  defp next_action(%{allowed_action: "send"} = item, _change, _repo) do
    %{
      action: "send-session",
      priority: "normal",
      safety: "gated",
      reason: item.reason
    }
  end

  defp next_action(item, _change, _repo) do
    %{
      action: item.allowed_action,
      priority: "normal",
      safety: action_safety(item.allowed_action),
      reason: item.reason
    }
  end

  defp maybe_put_reason(action, ""), do: action
  defp maybe_put_reason(action, reason), do: Map.put(action, :policy_reason, reason)

  defp action_safety("capture"), do: "safe"
  defp action_safety("capture-first"), do: "safe"
  defp action_safety("send"), do: "gated"
  defp action_safety("mark-managed"), do: "manual"
  defp action_safety("resume-adopt"), do: "manual"
  defp action_safety("stream-adopt"), do: "manual"
  defp action_safety("adopt"), do: "manual"
  defp action_safety(_action), do: "inspect"

  defp handoff(item, change, directive, repo) do
    %{
      focus: first_present([item.task, item.summary, item.title, item.current_path]),
      context: handoff_context(item),
      cautions: handoff_cautions(item, change, directive, repo),
      suggested_message: suggested_message(item, change, repo)
    }
  end

  defp handoff_context(item) do
    %{
      session: item.ref,
      project: item.project,
      pane: item.pane,
      path: item.current_path,
      work_state: item.work_state,
      allowed_action: item.allowed_action
    }
  end

  defp handoff_cautions(item, change, directive, repo) do
    []
    |> maybe_caution(repo.blockers != [], "repo has blockers: #{Enum.join(repo.blockers, ",")}")
    |> maybe_caution(repo.risks != [], "repo risks: #{Enum.join(repo.risks, ",")}")
    |> maybe_caution(not item.can_direct, "not directable: #{item.reason}")
    |> maybe_caution(needs_attention?(change), "session needs attention")
    |> maybe_caution(
      awaiting_observation?(directive, change),
      "last directive has not been observed yet"
    )
    |> Enum.reverse()
  end

  defp maybe_caution(cautions, true, caution), do: [caution | cautions]
  defp maybe_caution(cautions, false, _caution), do: cautions

  defp needs_attention?(%{needs_attention: true}), do: true
  defp needs_attention?(_change), do: false

  defp awaiting_observation?(nil, _change), do: false

  defp awaiting_observation?(directive, change) do
    directive_state(directive, change) == "sent-awaiting-observation"
  end

  defp suggested_message(_item, _change, %{blockers: blockers}) when blockers != [] do
    "Pause session direction and resolve repo blocker: #{Enum.join(blockers, ", ")}."
  end

  defp suggested_message(%{can_direct: true}, %{needs_attention: true}, _repo) do
    "Report current status, what changed, and the next safe step."
  end

  defp suggested_message(_item, _change, _repo), do: ""

  defp first_present(values) do
    Enum.find_value(values, "", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end)
  end

  defp format_time(nil), do: nil
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
