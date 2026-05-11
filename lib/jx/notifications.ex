defmodule JX.Notifications do
  @moduledoc """
  Notification inbox derived from monitor events.
  """

  import Ecto.Query

  alias JX.MonitorEvents.Event
  alias JX.Notifications.Notification
  alias JX.Repo

  @notification_prefix "ntf-"
  @notifiable_kinds ~w(
    session.attention
    session.ready
    session.blocked
    session.awaiting_observation
    watch.completed
    watch.blocked
    ci.passed
    ci.failed
    ci.cancelled
    ci.superseded
    orchestrator.health
    call.handoff.open
    delegation.open
    delegation.review
    devide.workspace.blocked
    devide.workspace.needs_review
    external.wake
  )

  def statuses, do: Notification.statuses()
  def severities, do: Notification.severities()

  def record_events(events) do
    events
    |> Enum.filter(&notifiable?/1)
    |> Enum.map(&attrs_from_event/1)
    |> insert_new()
  end

  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Notification
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_ref(Keyword.get(opts, :ref))
    |> maybe_filter_project(Keyword.get(opts, :project))
    |> maybe_filter_severity(Keyword.get(opts, :severity))
    |> order_by([notification], desc: notification.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def acknowledge_all(opts \\ []) do
    now = DateTime.utc_now()

    query =
      Notification
      |> maybe_filter_status("unread")
      |> maybe_filter_ref(Keyword.get(opts, :ref))
      |> maybe_filter_project(Keyword.get(opts, :project))

    {count, _records} =
      Repo.update_all(query,
        set: [status: "acknowledged", acknowledged_at: now, updated_at: now]
      )

    {:ok, %{acknowledged: count}}
  end

  def acknowledge(notification_id) do
    case Repo.get_by(Notification, notification_id: notification_id) do
      nil ->
        {:error, :notification_not_found}

      notification ->
        notification
        |> Notification.changeset(%{
          status: "acknowledged",
          acknowledged_at: DateTime.utc_now()
        })
        |> Repo.update()
    end
  end

  def compact_unread(opts \\ []) do
    now = DateTime.utc_now()

    unread_notifications =
      Notification
      |> maybe_filter_status("unread")
      |> maybe_filter_ref(Keyword.get(opts, :ref))
      |> maybe_filter_project(Keyword.get(opts, :project))
      |> where([notification], notification.ref != "")
      |> order_by([notification],
        asc: notification.kind,
        asc: notification.ref,
        desc: notification.updated_at,
        desc: notification.id
      )
      |> Repo.all()

    groups = Enum.group_by(unread_notifications, &{&1.kind, &1.ref})

    {kept, dismissed, duplicate_groups} =
      Enum.reduce(groups, {[], [], 0}, fn
        {_key, [notification]}, {kept, dismissed, duplicate_groups} ->
          {[notification | kept], dismissed, duplicate_groups}

        {_key, [keep | duplicates]}, {kept, dismissed, duplicate_groups} ->
          {[keep | kept], duplicates ++ dismissed, duplicate_groups + 1}

        {_key, []}, acc ->
          acc
      end)

    dismissed_ids = Enum.map(dismissed, & &1.id)

    dismissed_count =
      case dismissed_ids do
        [] ->
          0

        ids ->
          {count, _records} =
            Notification
            |> where([notification], notification.id in ^ids)
            |> Repo.update_all(set: [status: "dismissed", updated_at: now])

          count
      end

    {:ok,
     %{
       scanned: length(unread_notifications),
       kept: length(kept),
       duplicate_groups: duplicate_groups,
       dismissed: dismissed_count,
       kept_ids: kept |> Enum.map(& &1.notification_id) |> Enum.sort(),
       dismissed_ids: dismissed |> Enum.map(& &1.notification_id) |> Enum.sort()
     }}
  end

  def summary(opts \\ []) do
    notifications = list(Keyword.put_new(opts, :limit, 500))

    %{
      total: length(notifications),
      unread_total: Enum.count(notifications, &(&1.status == "unread")),
      by_status: count_by(notifications, & &1.status),
      by_kind: count_by(notifications, & &1.kind),
      by_project: count_by(notifications, & &1.project),
      latest:
        notifications
        |> Enum.take(Keyword.get(opts, :latest, 10))
        |> Enum.map(&notification_summary/1)
    }
  end

  defp insert_new([]), do: %{saved: 0, notifications: [], errors: []}

  defp insert_new(attrs_list) do
    Repo.transaction(fn ->
      attrs_list
      |> Enum.reject(&duplicate_notification?/1)
      |> Enum.map(fn attrs ->
        %Notification{}
        |> Notification.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, notification} -> notification
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
    |> case do
      {:ok, notifications} ->
        %{saved: length(notifications), notifications: notifications, errors: []}

      {:error, reason} ->
        %{saved: 0, notifications: [], errors: [inspect(reason)]}
    end
  end

  defp duplicate_notification?(attrs) do
    source_event_recorded?(attrs.source_event_id) or active_notification?(attrs)
  end

  defp source_event_recorded?(source_event_id) do
    Notification
    |> where([notification], notification.source_event_id == ^source_event_id)
    |> limit(1)
    |> Repo.exists?()
  end

  defp active_notification?(%{ref: ref}) when ref in [nil, ""], do: false

  defp active_notification?(attrs) do
    Notification
    |> where(
      [notification],
      notification.kind == ^attrs.kind and notification.ref == ^attrs.ref and
        notification.status == "unread"
    )
    |> limit(1)
    |> Repo.exists?()
  end

  defp attrs_from_event(%Event{} = event) do
    %{
      notification_id: notification_id(),
      source_event_id: event.event_id,
      kind: event.kind,
      severity: event.severity,
      status: "unread",
      ref: event.ref || "",
      project: event.project || "",
      summary: event.summary || "",
      payload: event.payload || "{}"
    }
  end

  defp notifiable?(%Event{kind: kind, severity: severity}) do
    kind in @notifiable_kinds or severity in ["warning", "critical"]
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status),
    do: where(query, [notification], notification.status == ^status)

  defp maybe_filter_ref(query, nil), do: query
  defp maybe_filter_ref(query, ref), do: where(query, [notification], notification.ref == ^ref)

  defp maybe_filter_project(query, nil), do: query

  defp maybe_filter_project(query, project),
    do: where(query, [notification], notification.project == ^project)

  defp maybe_filter_severity(query, nil), do: query

  defp maybe_filter_severity(query, severity),
    do: where(query, [notification], notification.severity == ^severity)

  defp count_by(items, fun) do
    items
    |> Enum.map(fun)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
  end

  defp notification_summary(%Notification{} = notification) do
    %{
      notification_id: notification.notification_id,
      source_event_id: notification.source_event_id,
      kind: notification.kind,
      severity: notification.severity,
      status: notification.status,
      ref: notification.ref,
      project: notification.project,
      summary: notification.summary,
      acknowledged_at: notification.acknowledged_at,
      inserted_at: notification.inserted_at,
      updated_at: notification.updated_at
    }
  end

  defp notification_id do
    @notification_prefix <>
      (5
       |> :crypto.strong_rand_bytes()
       |> Base.encode16(case: :lower))
  end
end
