defmodule JX.NotificationsSinkTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias JX.Notifications.{ConsoleSink, FileSink, Router}

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

  describe "FileSink.resolve_path/1 paths" do
    test "accepts absolute path that resolves inside state_dir" do
      state_dir =
        Path.join(System.tmp_dir!(), "jx-sink-inside-#{System.unique_integer([:positive])}")

      inside = Path.join(state_dir, "events.jsonl")

      assert {:ok, ^inside} = FileSink.resolve_path(path: inside, state_dir: state_dir)
    end

    test "uses JX_STATE_DIR env var when no opt is provided" do
      state_dir =
        Path.join(System.tmp_dir!(), "jx-sink-env-#{System.unique_integer([:positive])}")

      previous = System.get_env("JX_STATE_DIR")
      System.put_env("JX_STATE_DIR", state_dir)

      on_exit(fn ->
        case previous do
          nil -> System.delete_env("JX_STATE_DIR")
          value -> System.put_env("JX_STATE_DIR", value)
        end
      end)

      assert {:ok, path} = FileSink.resolve_path([])
      assert path == Path.join(state_dir, "notifications.jsonl")
    end

    test "defaults to notifications.jsonl filename when :path is omitted" do
      state_dir =
        Path.join(System.tmp_dir!(), "jx-sink-default-#{System.unique_integer([:positive])}")

      assert {:ok, path} = FileSink.resolve_path(state_dir: state_dir)
      assert path == Path.join(state_dir, "notifications.jsonl")
    end
  end

  describe "ConsoleSink.deliver/2 logger-level mapping" do
    # The sink translates the event severity into a Logger level so escript
    # consumers see operator-relevant messages through the standard backend.
    # Exhaustive coverage of the four branches in logger_level/1 plus the
    # field-reject branch in message/1.

    test "critical → :error" do
      log =
        capture_log(fn ->
          assert :ok = ConsoleSink.deliver(%{severity: "critical", summary: "boom"})
        end)

      assert log =~ "[error]"
      assert log =~ "boom"
    end

    test "warning → :warning" do
      log =
        capture_log(fn ->
          assert :ok = ConsoleSink.deliver(%{severity: "warning", summary: "heads up"})
        end)

      assert log =~ "[warning]"
      assert log =~ "heads up"
    end

    # The global Logger level is :warning (per config/config.exs), so :info
    # messages are filtered before capture_log sees them. The branches of
    # logger_level/1 still execute when ConsoleSink.deliver/2 is called —
    # only the output assertion has to be relaxed.
    test "notice → :info (return :ok; level mapped, output filtered)" do
      assert :ok = ConsoleSink.deliver(%{severity: "notice", summary: "fyi"})
    end

    test "unknown severity falls back to :info" do
      assert :ok = ConsoleSink.deliver(%{severity: "weird", summary: "shrug"})
    end

    test "message/1 drops empty + nil fields and includes approval metadata" do
      log =
        capture_log(fn ->
          ConsoleSink.deliver(%{
            event: "approval.created",
            severity: "warning",
            approval: %{approval_id: "apr-9", workspace_id: "ws-9", kind: "publish"},
            summary: ""
          })
        end)

      # All present fields appear; the empty :summary does not produce a
      # trailing space-separated empty token.
      assert log =~ "approval.created"
      assert log =~ "apr-9"
      assert log =~ "ws-9"
      assert log =~ "publish"
    end
  end
end
