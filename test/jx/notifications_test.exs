defmodule JX.NotificationsTest do
  use ExUnit.Case, async: false

  alias JX.MonitorEvents.Event
  alias JX.Notifications
  alias JX.Notifications.Notification
  alias JX.Repo

  setup do
    Repo.delete_all(Notification)
    :ok
  end

  test "record_events keeps one unread notification per kind and ref" do
    first = event("evt-first", "session.blocked", "s-one", "first blocked summary")
    second = event("evt-second", "session.blocked", "s-one", "changed blocked summary")

    assert %{saved: 1, notifications: [notification], errors: []} =
             Notifications.record_events([first])

    assert %{saved: 0, notifications: [], errors: []} = Notifications.record_events([second])

    assert [%Notification{notification_id: notification_id, summary: "first blocked summary"}] =
             Notifications.list(status: "unread", ref: "s-one")

    assert notification.notification_id == notification_id

    assert {:ok, %Notification{}} = Notifications.acknowledge(notification_id)

    assert %{saved: 1, notifications: [%Notification{summary: "changed blocked summary"}]} =
             Notifications.record_events([second])
  end

  test "compact_unread dismisses older duplicate unread notifications" do
    old = insert_notification!("ntf-old", "evt-old", "session.blocked", "s-one", "old")
    new = insert_notification!("ntf-new", "evt-new", "session.blocked", "s-one", "new")
    other_kind = insert_notification!("ntf-other", "evt-other", "session.ready", "s-one", "ready")

    acknowledged =
      insert_notification!("ntf-ack", "evt-ack", "session.blocked", "s-one", "acknowledged",
        status: "acknowledged"
      )

    assert {:ok,
            %{
              scanned: 3,
              kept: 2,
              duplicate_groups: 1,
              dismissed: 1,
              kept_ids: kept_ids,
              dismissed_ids: ["ntf-old"]
            }} = Notifications.compact_unread()

    assert Enum.sort(kept_ids) == Enum.sort([new.notification_id, other_kind.notification_id])

    assert %Notification{status: "dismissed"} =
             Repo.get_by!(Notification, notification_id: old.notification_id)

    assert %Notification{status: "unread"} =
             Repo.get_by!(Notification, notification_id: new.notification_id)

    assert %Notification{status: "unread"} =
             Repo.get_by!(Notification, notification_id: other_kind.notification_id)

    assert %Notification{status: "acknowledged"} =
             Repo.get_by!(Notification, notification_id: acknowledged.notification_id)
  end

  test "compact_unread can be scoped by ref" do
    insert_notification!("ntf-one-old", "evt-one-old", "session.blocked", "s-one", "old")
    insert_notification!("ntf-one-new", "evt-one-new", "session.blocked", "s-one", "new")
    insert_notification!("ntf-two-old", "evt-two-old", "session.blocked", "s-two", "old")
    insert_notification!("ntf-two-new", "evt-two-new", "session.blocked", "s-two", "new")

    assert {:ok, %{scanned: 2, dismissed: 1, dismissed_ids: ["ntf-one-old"]}} =
             Notifications.compact_unread(ref: "s-one")

    assert %Notification{status: "dismissed"} =
             Repo.get_by!(Notification, notification_id: "ntf-one-old")

    assert %Notification{status: "unread"} =
             Repo.get_by!(Notification, notification_id: "ntf-two-old")
  end

  test "summary latest entries are json encodable snapshots" do
    insert_notification!("ntf-summary", "evt-summary", "session.blocked", "s-one", "summary")

    assert %{latest: [%{notification_id: "ntf-summary", status: "unread"}]} =
             summary = Notifications.summary(status: "unread")

    assert is_binary(Jason.encode!(summary))
  end

  defp event(event_id, kind, ref, summary) do
    %Event{
      event_id: event_id,
      kind: kind,
      severity: "warning",
      ref: ref,
      project: "saysure",
      summary: summary,
      payload: "{}"
    }
  end

  defp insert_notification!(notification_id, source_event_id, kind, ref, summary, opts \\ []) do
    attrs = %{
      notification_id: notification_id,
      source_event_id: source_event_id,
      kind: kind,
      severity: Keyword.get(opts, :severity, "warning"),
      status: Keyword.get(opts, :status, "unread"),
      ref: ref,
      project: Keyword.get(opts, :project, "saysure"),
      summary: summary,
      payload: "{}"
    }

    %Notification{}
    |> Notification.changeset(attrs)
    |> Repo.insert!()
  end
end
