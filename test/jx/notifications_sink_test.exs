defmodule JX.NotificationsSinkTest do
  use ExUnit.Case, async: true

  alias JX.Notifications.{FileSink, Router}

  test "file sink writes redacted JSONL under state dir" do
    state_dir =
      Path.join(System.tmp_dir!(), "jx-notification-sink-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(state_dir) end)

    event = %{
      event: "approval.created",
      severity: "warning",
      summary: "Bearer super-secret",
      api_token: "super-secret",
      approval: %{approval_id: "apr-1", workspace_id: "ws-1"}
    }

    result =
      Router.route(event,
        sinks: [
          {FileSink, [path: "events.jsonl", state_dir: state_dir]}
        ]
      )

    assert result.errors == []
    assert result.delivered == 1

    path = Path.join(state_dir, "events.jsonl")
    assert File.exists?(path)

    [line] = path |> File.read!() |> String.split("\n", trim: true)
    assert {:ok, payload} = Jason.decode(line)

    refute line =~ "super-secret"
    assert payload["api_token"] == "<redacted>"
    assert payload["summary"] =~ "<redacted>"
  end

  test "file sink rejects absolute paths outside state dir" do
    state_dir =
      Path.join(System.tmp_dir!(), "jx-notification-sink-#{System.unique_integer([:positive])}")

    outside = Path.join(System.tmp_dir!(), "jx-notification-outside.jsonl")

    assert {:error, {:unsafe_notification_path, ^outside, _state_dir}} =
             FileSink.resolve_path(path: outside, state_dir: state_dir)
  end
end
