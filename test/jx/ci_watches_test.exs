defmodule JX.CiWatchesTest do
  use ExUnit.Case, async: false

  alias JX.CiWatches
  alias JX.CiWatches.CiWatch
  alias JX.MonitorEvents
  alias JX.MonitorEvents.Event
  alias JX.Notifications
  alias JX.Notifications.Notification
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Repo
  alias JX.SessionProfiles.SessionProfile

  setup do
    Repo.delete_all(Notification)
    Repo.delete_all(Event)
    Repo.delete_all(OrchestrationAction)
    Repo.delete_all(SessionProfile)
    Repo.delete_all(CiWatch)

    :ok
  end

  test "passed prompt-mode watch chambers a draft profile prompt" do
    {:ok, watch} =
      CiWatches.add_watch(%{
        repo: "org/repo",
        pr_number: 12,
        ref: "s-ci",
        project: "repo",
        mode: "prompt",
        goal: "unblock dependent PR",
        success_prompt: "Rerun the dependent PR checks and report the result."
      })

    update = CiWatches.apply_digest(watch, digest("pass", 12))

    assert update.previous_status == "active"
    assert update.status == "passed"
    assert update.changed?
    assert update.profile_action.action == "ci-chamber-prompt"

    assert %SessionProfile{
             prompt_status: "draft",
             next_prompt: "Rerun the dependent PR checks and report the result."
           } = Repo.get_by!(SessionProfile, ref: "s-ci")

    assert %CiWatch{status: "passed", completed_at: completed_at, last_overall: "pass"} =
             Repo.get_by!(CiWatch, watch_id: watch.watch_id)

    assert %DateTime{} = completed_at

    assert %OrchestrationAction{source: "ci-watch", status: "executed"} =
             Repo.get_by!(OrchestrationAction, ref: "s-ci")
  end

  test "failed hold-mode watch marks the profile blocked" do
    {:ok, watch} =
      CiWatches.add_watch(%{
        repo: "org/repo",
        pr_number: 13,
        ref: "s-ci",
        mode: "hold",
        goal: "watch CI failure"
      })

    update = CiWatches.apply_digest(watch, digest("fail", 13))

    assert update.status == "failed"
    assert update.profile_action.action == "ci-hold-profile"

    assert %SessionProfile{
             prompt_status: "blocked",
             strategy: strategy,
             notes: notes
           } = Repo.get_by!(SessionProfile, ref: "s-ci")

    assert strategy =~ "Held by CI watch"
    assert notes =~ "PR #13 checks failed"
  end

  test "pending watch remains active without profile mutation" do
    {:ok, watch} =
      CiWatches.add_watch(%{
        repo: "org/repo",
        pr_number: 14,
        ref: "s-ci",
        mode: "prompt",
        success_prompt: "Proceed"
      })

    update = CiWatches.apply_digest(watch, digest("pending", 14))

    refute update.changed?
    assert update.status == "active"
    refute Map.has_key?(update, :profile_action)
    assert Repo.get_by(SessionProfile, ref: "s-ci") == nil
  end

  test "watch is superseded when the live PR head changed" do
    old_head = String.duplicate("a", 40)
    new_head = String.duplicate("b", 40)

    {:ok, watch} =
      CiWatches.add_watch(%{
        repo: "org/repo",
        pr_number: 16,
        ref: "s-ci",
        project: "repo",
        mode: "hold",
        head_sha: old_head,
        goal: "watch the current PR head"
      })

    update =
      watch
      |> CiWatches.apply_digest(digest("fail", 16) |> Map.put(:head_sha, new_head))

    assert update.previous_status == "active"
    assert update.status == "superseded"
    assert update.changed?
    refute Map.has_key?(update, :profile_action)

    assert %CiWatch{
             status: "superseded",
             head_sha: ^old_head,
             last_head_sha: ^new_head,
             last_summary: summary
           } = Repo.get_by!(CiWatch, watch_id: watch.watch_id)

    assert summary =~ "superseded"

    assert {:ok, [event]} = MonitorEvents.record_scan(%{ci_watch_updates: [update]})
    assert event.kind == "ci.superseded"

    assert %{saved: 1, notifications: [notification]} = Notifications.record_events([event])
    assert notification.kind == "ci.superseded"
  end

  test "monitor events and notifications include terminal CI watch updates" do
    {:ok, watch} =
      CiWatches.add_watch(%{
        repo: "org/repo",
        pr_number: 15,
        ref: "s-ci",
        project: "repo",
        mode: "notify"
      })

    update = CiWatches.apply_digest(watch, digest("fail", 15))

    assert {:ok, [event]} = MonitorEvents.record_scan(%{ci_watch_updates: [update]})
    assert event.kind == "ci.failed"
    assert event.ref == "s-ci"
    assert event.project == "repo"
    assert event.summary =~ "CI watch failed"

    assert %{saved: 1, notifications: [notification]} = Notifications.record_events([event])
    assert notification.kind == "ci.failed"
    assert notification.ref == "s-ci"
  end

  defp digest(overall, pr_number) do
    %{
      repo: "org/repo",
      pr: pr_number,
      overall: overall,
      totals: %{
        "total" => 3,
        "pass" => if(overall == "pass", do: 3, else: 2),
        "fail" => if(overall == "fail", do: 1, else: 0),
        "pending" => if(overall == "pending", do: 1, else: 0),
        "skipping" => 0,
        "cancel" => 0
      },
      blockers:
        if overall == "fail" do
          [
            %{
              check: "Test",
              workflow: "CI",
              link: "https://example.test/job/1",
              type: "test-failure",
              summary: "1 test failure",
              evidence: "failed assertion",
              warnings: []
            }
          ]
        else
          []
        end,
      checks: []
    }
  end
end
