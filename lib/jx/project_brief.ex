defmodule JX.ProjectBrief do
  @moduledoc """
  Builds a project-scoped gateway brief from portfolio and orchestration state.
  """

  def build(project_name, data, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    portfolio = field(data, :portfolio, %{}) || %{}
    call_brief = field(data, :call_brief, %{}) || %{}
    next_step = field(data, :next_step, %{}) || %{}
    playbook = field(data, :playbook, %{}) || %{}

    project =
      project_snapshot(
        project_name,
        field(data, :project),
        portfolio
      )

    notifications =
      data
      |> field(:notifications, [])
      |> Enum.take(limit)
      |> Enum.map(&notification_summary/1)

    ci_watches =
      data
      |> field(:ci_watches, [])
      |> Enum.take(limit)
      |> Enum.map(&ci_watch_summary/1)

    handoffs =
      data
      |> field(:handoffs, [])
      |> Enum.take(limit)
      |> Enum.map(&handoff_summary/1)

    delegation_reviews =
      data
      |> field(:delegation_reviews, [])
      |> Enum.take(limit)
      |> Enum.map(&delegation_review_summary/1)

    delegations =
      data
      |> field(:delegations, [])
      |> Enum.take(limit)
      |> Enum.map(&delegation_summary/1)

    wake_triggers =
      data
      |> field(:wake_triggers, [])
      |> Enum.take(limit)
      |> Enum.map(&wake_trigger_summary/1)

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      project: project,
      headline: field(call_brief, :headline, "No active project agenda."),
      next: next_step,
      mode: mode_summary(next_step, playbook),
      counts: %{
        sessions: field(project, :sessions_total, 0),
        attention_sessions: field(project, :attention_total, 0),
        directable_sessions: field(project, :directable_total, 0),
        notifications: length(notifications),
        ci_watches: length(ci_watches),
        handoffs: length(handoffs),
        delegation_reviews: length(delegation_reviews),
        delegations: length(delegations),
        wake_triggers: length(wake_triggers)
      },
      agenda: call_brief |> field(:agenda, []) |> Enum.take(limit),
      refs: project |> field(:refs, []) |> Enum.take(limit),
      notifications: notifications,
      ci_watches: ci_watches,
      handoffs: handoffs,
      delegation_reviews: delegation_reviews,
      delegations: delegations,
      wake_triggers: wake_triggers,
      commands: commands(project_name, next_step)
    }
  end

  defp project_snapshot(project_name, registered_project, portfolio) do
    portfolio_project =
      portfolio
      |> field(:projects, [])
      |> Enum.find(&(field(&1, :name) == project_name))

    base =
      cond do
        is_map(portfolio_project) ->
          portfolio_project

        is_map(registered_project) ->
          registered_project_summary(registered_project)

        true ->
          %{name: project_name, registered: false, sessions_total: 0, refs: []}
      end

    Map.put_new(base, :name, project_name)
  end

  defp registered_project_summary(project) do
    host = field(project, :host)

    %{
      name: field(project, :name, ""),
      slug: field(project, :slug, ""),
      registered: true,
      host: field(host, :name, ""),
      transport: field(host, :transport, ""),
      ssh_target: field(host, :ssh_target, ""),
      workspace_path: field(host, :workspace_path, ""),
      repo_path: field(project, :repo_path, ""),
      sessions_total: 0,
      refs: []
    }
  end

  defp mode_summary(next_step, playbook) do
    %{
      id: field(next_step, :mode, ""),
      title: field(next_step, :mode_title, ""),
      entrypoint: field(playbook, :entrypoint, field(next_step, :command, "")),
      safety: field(playbook, :safety, ""),
      handoff: field(playbook, :handoff, "")
    }
  end

  defp notification_summary(notification) do
    %{
      notification_id: field(notification, :notification_id, ""),
      kind: field(notification, :kind, ""),
      severity: field(notification, :severity, ""),
      ref: field(notification, :ref, ""),
      summary: field(notification, :summary, ""),
      status: field(notification, :status, "")
    }
  end

  defp ci_watch_summary(watch) do
    %{
      watch_id: field(watch, :watch_id, ""),
      repo: field(watch, :repo, ""),
      pr_number: field(watch, :pr_number, nil),
      ref: field(watch, :ref, ""),
      status: field(watch, :status, ""),
      mode: field(watch, :mode, ""),
      summary: field(watch, :last_summary, field(watch, :goal, ""))
    }
  end

  defp handoff_summary(handoff) do
    %{
      handoff_id: field(handoff, :handoff_id, ""),
      surface: field(handoff, :surface, ""),
      ref: field(handoff, :ref, ""),
      status: field(handoff, :status, ""),
      title: field(handoff, :title, ""),
      summary: field(handoff, :summary, "")
    }
  end

  defp delegation_review_summary(review) do
    %{
      delegation_id: field(review, :delegation_id, ""),
      ref: field(review, :ref, ""),
      status: field(review, :status, ""),
      decision: field(review, :decision, ""),
      summary: field(review, :summary, ""),
      warnings: field(review, :warnings, [])
    }
  end

  defp delegation_summary(delegation) do
    %{
      delegation_id: field(delegation, :delegation_id, ""),
      ref: field(delegation, :ref, ""),
      status: field(delegation, :status, ""),
      title: field(delegation, :title, ""),
      summary: field(delegation, :worker_summary, field(delegation, :brief, ""))
    }
  end

  defp wake_trigger_summary(trigger) do
    %{
      trigger_id: field(trigger, :trigger_id, ""),
      status: field(trigger, :status, ""),
      schedule: field(trigger, :schedule, ""),
      severity: field(trigger, :severity, ""),
      ref: field(trigger, :ref, ""),
      message: field(trigger, :message, ""),
      next_run_at: format_time(field(trigger, :next_run_at))
    }
  end

  defp commands(project_name, next_step) do
    [
      field(next_step, :command),
      "jx project brief #{project_name} --observe --json",
      "jx notifications ls --project #{project_name} --status unread --json",
      "jx sessions profiles --project #{project_name} --json"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp field(value, key, default) do
    if function_exported?(value.__struct__, :__schema__, 1) do
      Map.get(value, key, default)
    else
      default
    end
  rescue
    _error -> default
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value), do: value in [nil, "", []]

  defp format_time(nil), do: nil
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value), do: value
end
