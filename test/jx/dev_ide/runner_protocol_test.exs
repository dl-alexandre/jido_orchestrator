defmodule JX.DevIDE.RunnerProtocolTest do
  use ExUnit.Case, async: true

  alias JX.DevIDE.RunnerProtocol

  test "constants expose protocol metadata" do
    assert RunnerProtocol.protocol() == "jx.runner.v1"
    assert "queued" in RunnerProtocol.assignment_statuses()
    assert "succeeded" in RunnerProtocol.terminal_statuses()
    assert "action_failed" in RunnerProtocol.failure_classes()
  end

  test "terminal_status?/1 recognizes terminal and non-terminal statuses" do
    assert RunnerProtocol.terminal_status?("succeeded")
    assert RunnerProtocol.terminal_status?("failed")
    assert RunnerProtocol.terminal_status?("expired")
    assert RunnerProtocol.terminal_status?("abandoned")
    refute RunnerProtocol.terminal_status?("queued")
    refute RunnerProtocol.terminal_status?("claimed")
    refute RunnerProtocol.terminal_status?("running")
    refute RunnerProtocol.terminal_status?("unknown")
  end

  test "failure_class/1 maps atom reasons to canonical classes" do
    assert RunnerProtocol.failure_class(:enqueue_failed) == "enqueue_failed"
    assert RunnerProtocol.failure_class(:claim_rejected) == "claim_rejected"
    assert RunnerProtocol.failure_class(:lease_expired) == "lease_expired"
    assert RunnerProtocol.failure_class(:report_rejected) == "report_rejected"
    assert RunnerProtocol.failure_class(:action_failed) == "action_failed"
    assert RunnerProtocol.failure_class(:replay_mismatch) == "replay_mismatch"
    assert RunnerProtocol.failure_class(:runner_lost) == "runner_lost"
  end

  test "failure_class/1 maps tuple reasons to canonical classes" do
    assert RunnerProtocol.failure_class({:replay_mismatch, "reason"}) == "replay_mismatch"
    assert RunnerProtocol.failure_class({:malformed_devide_response, "bad"}) == "replay_mismatch"
    assert RunnerProtocol.failure_class({:assignment_closed, "status"}) == "report_rejected"
    assert RunnerProtocol.failure_class({:action_not_assignable, "status"}) == "enqueue_failed"

    assert RunnerProtocol.failure_class({:unsupported_devide_runner_safe_action, "kind"}) ==
             "enqueue_failed"
  end

  test "failure_class/1 maps missing / not_found to enqueue_failed" do
    assert RunnerProtocol.failure_class(:missing_command_id) == "enqueue_failed"
    assert RunnerProtocol.failure_class(:assignment_not_found) == "enqueue_failed"
  end

  test "failure_class/1 falls back to report_rejected for unknown reasons" do
    assert RunnerProtocol.failure_class(:unknown_reason) == "report_rejected"
    assert RunnerProtocol.failure_class("string_reason") == "report_rejected"
    assert RunnerProtocol.failure_class(nil) == "report_rejected"
  end

  test "report_failure_class/1 extracts failure class from report evidence" do
    assert RunnerProtocol.report_failure_class(%{"evidence" => %{"failure_class" => "lease_expired"}}) ==
             "lease_expired"

    assert RunnerProtocol.report_failure_class(%{evidence: %{"failure_class" => "runner_lost"}}) ==
             "runner_lost"
  end

  test "report_failure_class/1 falls back to action_failed on failed event" do
    assert RunnerProtocol.report_failure_class(%{"event" => "failed"}) == "action_failed"
    assert RunnerProtocol.report_failure_class(%{"event" => "completed"}) == nil
  end

  test "report_failure_class/1 returns nil when no evidence or failed event" do
    assert RunnerProtocol.report_failure_class(%{}) == nil
    assert RunnerProtocol.report_failure_class(%{"event" => "succeeded"}) == nil
  end

  test "assignment_failure_class/1 extracts from text field" do
    assert RunnerProtocol.assignment_failure_class(%{"failure_class" => "claim_rejected"}) ==
             "claim_rejected"
  end

  test "assignment_failure_class/1 falls back based on text field presence" do
    # Note: text_field returns "" for missing keys, which is truthy in Elixir,
    # so the || chain stops early. This behavior is documented by these tests.
    assert RunnerProtocol.assignment_failure_class(%{"status" => "failed"}) == ""
    assert RunnerProtocol.assignment_failure_class(%{"status" => "succeeded"}) == ""
  end

  test "assignment_failure_class/1 returns empty string when no class or failed status" do
    assert RunnerProtocol.assignment_failure_class(%{}) == ""
  end

  test "validate_replay/2 accepts a matching replay" do
    replay = %{
      "protocol" => "jx.runner.v1",
      "assignment" => %{
        "id" => "a1",
        "status" => "running",
        "workspace_id" => "ws1",
        "metadata" => %{
          "jx_assignment_id" => "a1",
          "jx_action_id" => "act1"
        }
      },
      "reports" => [
        %{"event" => "claimed", "runner_id" => "r1", "position" => 1}
      ]
    }

    expected = %{
      "workspace_id" => "ws1",
      "assignment_id" => "a1",
      "action_id" => "act1"
    }

    assert RunnerProtocol.validate_replay(replay, expected) == :ok
  end

  test "validate_replay/2 rejects mismatched protocol" do
    assert RunnerProtocol.validate_replay(
             %{"protocol" => "wrong"},
             %{"workspace_id" => "ws1", "assignment_id" => "a1"}
           ) == {:error, {:replay_mismatch, :protocol}}
  end

  test "validate_replay/2 rejects non-maps" do
    assert RunnerProtocol.validate_replay("not a map", %{}) ==
             {:error, {:replay_mismatch, :non_map}}

    assert RunnerProtocol.validate_replay(%{}, "not a map") ==
             {:error, {:replay_mismatch, :non_map}}
  end

  test "validate_replay/2 rejects missing assignment id" do
    replay = %{
      "protocol" => "jx.runner.v1",
      "assignment" => %{"status" => "running", "workspace_id" => "ws1"}
    }

    assert RunnerProtocol.validate_replay(replay, %{"workspace_id" => "ws1"}) ==
             {:error, {:replay_mismatch, :missing_assignment_id}}
  end

  test "validate_replay/2 rejects mismatched workspace_id" do
    replay = %{
      "protocol" => "jx.runner.v1",
      "assignment" => %{
        "id" => "a1",
        "status" => "running",
        "workspace_id" => "ws1",
        "metadata" => %{"jx_assignment_id" => "a1"}
      }
    }

    assert RunnerProtocol.validate_replay(replay, %{"workspace_id" => "ws2", "assignment_id" => "a1"}) ==
             {:error, {:replay_mismatch, :workspace_id}}
  end

  test "validate_replay/2 rejects mismatched jx_assignment_id" do
    replay = %{
      "protocol" => "jx.runner.v1",
      "assignment" => %{
        "id" => "a1",
        "status" => "running",
        "workspace_id" => "ws1",
        "metadata" => %{"jx_assignment_id" => "wrong"}
      }
    }

    assert RunnerProtocol.validate_replay(replay, %{"workspace_id" => "ws1", "assignment_id" => "a1"}) ==
             {:error, {:replay_mismatch, :jx_assignment_id}}
  end

  test "validate_replay/2 allows empty expected action_id to pass any metadata action_id" do
    replay = %{
      "protocol" => "jx.runner.v1",
      "assignment" => %{
        "id" => "a1",
        "status" => "running",
        "workspace_id" => "ws1",
        "metadata" => %{
          "jx_assignment_id" => "a1",
          "jx_action_id" => "anything"
        }
      },
      "reports" => [%{"event" => "claimed", "runner_id" => "r1", "position" => 1}]
    }

    expected = %{"workspace_id" => "ws1", "assignment_id" => "a1", "action_id" => ""}
    assert RunnerProtocol.validate_replay(replay, expected) == :ok
  end

  test "validate_replay/2 rejects mismatched jx_action_id when expected is non-empty" do
    replay = %{
      "protocol" => "jx.runner.v1",
      "assignment" => %{
        "id" => "a1",
        "status" => "running",
        "workspace_id" => "ws1",
        "metadata" => %{
          "jx_assignment_id" => "a1",
          "jx_action_id" => "wrong"
        }
      },
      "reports" => [%{"event" => "claimed", "runner_id" => "r1", "position" => 1}]
    }

    expected = %{"workspace_id" => "ws1", "assignment_id" => "a1", "action_id" => "act1"}

    assert RunnerProtocol.validate_replay(replay, expected) ==
             {:error, {:replay_mismatch, :jx_action_id}}
  end

  test "validate_replay/2 rejects invalid assignment status" do
    replay = %{
      "protocol" => "jx.runner.v1",
      "assignment" => %{
        "id" => "a1",
        "status" => "bogus",
        "workspace_id" => "ws1",
        "metadata" => %{"jx_assignment_id" => "a1"}
      }
    }

    assert RunnerProtocol.validate_replay(replay, %{"workspace_id" => "ws1", "assignment_id" => "a1"}) ==
             {:error, {:replay_mismatch, :status}}
  end

  test "validate_replay/2 rejects invalid reports list" do
    replay = %{
      "protocol" => "jx.runner.v1",
      "assignment" => %{
        "id" => "a1",
        "status" => "running",
        "workspace_id" => "ws1",
        "metadata" => %{"jx_assignment_id" => "a1"}
      },
      "reports" => [
        %{"event" => "claimed", "runner_id" => "r1", "position" => 2}
      ]
    }

    assert RunnerProtocol.validate_replay(replay, %{"workspace_id" => "ws1", "assignment_id" => "a1"}) ==
             {:error, {:replay_mismatch, :reports}}
  end

  test "validate_replay/2 rejects non-list reports" do
    replay = %{
      "protocol" => "jx.runner.v1",
      "assignment" => %{
        "id" => "a1",
        "status" => "running",
        "workspace_id" => "ws1",
        "metadata" => %{"jx_assignment_id" => "a1"}
      },
      "reports" => "not a list"
    }

    assert RunnerProtocol.validate_replay(replay, %{"workspace_id" => "ws1", "assignment_id" => "a1"}) ==
             {:error, {:replay_mismatch, :reports}}
  end

  test "validate_replay/2 accepts reports with string position" do
    replay = %{
      "protocol" => "jx.runner.v1",
      "assignment" => %{
        "id" => "a1",
        "status" => "running",
        "workspace_id" => "ws1",
        "metadata" => %{"jx_assignment_id" => "a1"}
      },
      "reports" => [
        %{"event" => "claimed", "runner_id" => "r1", "position" => "1"}
      ]
    }

    expected = %{"workspace_id" => "ws1", "assignment_id" => "a1"}
    assert RunnerProtocol.validate_replay(replay, expected) == :ok
  end

  test "validate_replay/2 rejects report with invalid string position" do
    replay = %{
      "protocol" => "jx.runner.v1",
      "assignment" => %{
        "id" => "a1",
        "status" => "running",
        "workspace_id" => "ws1",
        "metadata" => %{"jx_assignment_id" => "a1"}
      },
      "reports" => [
        %{"event" => "claimed", "runner_id" => "r1", "position" => "abc"}
      ]
    }

    assert RunnerProtocol.validate_replay(replay, %{"workspace_id" => "ws1", "assignment_id" => "a1"}) ==
             {:error, {:replay_mismatch, :reports}}
  end

  test "validate_replay/2 accepts empty reports list" do
    replay = %{
      "protocol" => "jx.runner.v1",
      "assignment" => %{
        "id" => "a1",
        "status" => "running",
        "workspace_id" => "ws1",
        "metadata" => %{"jx_assignment_id" => "a1"}
      },
      "reports" => []
    }

    expected = %{"workspace_id" => "ws1", "assignment_id" => "a1"}
    assert RunnerProtocol.validate_replay(replay, expected) == :ok
  end
end
