defmodule JX.SessionProfilesTest do
  use ExUnit.Case, async: false

  alias JX.Repo
  alias JX.SessionProfiles
  alias JX.SessionProfiles.SessionProfile

  setup do
    Repo.delete_all(SessionProfile)
    :ok
  end

  test "profile timing uses fresh observations before stale profile update time" do
    ref = "s-fresh-observation"
    now = ~U[2026-04-27 12:00:00Z]
    old_seen_at = DateTime.add(now, -600, :second)

    assert {:ok, _profile} =
             SessionProfiles.upsert_session_profile(ref, %{
               objective: "track CI worker",
               expected_completion: "after CI completes",
               stale_after_seconds: 60,
               last_seen_at: old_seen_at
             })

    report =
      SessionProfiles.build_report(dossier_report(ref, DateTime.add(now, -10, :second)),
        now: now
      )

    assert [%{timing: timing}] = report.profiles
    assert timing.last_observation_age_seconds == 10
    assert timing.last_seen_age_seconds == 600
    assert timing.stale == false
    assert timing.check_status == "fresh"
    assert timing.next_check == "continue scheduled monitoring"
  end

  test "profile timing marks sessions stale when the latest observation exceeds threshold" do
    ref = "s-stale-observation"
    now = ~U[2026-04-27 12:00:00Z]

    assert {:ok, _profile} =
             SessionProfiles.upsert_session_profile(ref, %{
               objective: "track CI worker",
               expected_completion: "after CI completes",
               stale_after_seconds: 60,
               last_seen_at: DateTime.add(now, -10, :second)
             })

    report =
      SessionProfiles.build_report(dossier_report(ref, DateTime.add(now, -120, :second)),
        now: now
      )

    assert [%{timing: timing}] = report.profiles
    assert timing.last_observation_age_seconds == 120
    assert timing.last_seen_age_seconds == 10
    assert timing.stale == true
    assert timing.check_status == "stale"
    assert timing.next_check == "observe session now"
  end

  defp dossier_report(ref, observed_at) do
    %{
      generated_at: observed_at,
      observed: false,
      observation_refresh: %{observed: false},
      errors: [],
      dossiers: [dossier(ref, observed_at)]
    }
  end

  defp dossier(ref, observed_at) do
    %{
      ref: ref,
      host: "local",
      type: "agent",
      kind: "claude",
      agent_name: "claude",
      project: "saysure",
      control_mode: "managed",
      can_direct: true,
      pane: "default/main:0.0",
      current_path: "/repo",
      tmux_server: "default",
      session_name: "main",
      window: 0,
      pane_index: 0,
      task: "",
      summary: "Ready for next step.",
      title: "Claude",
      work_state: "idle",
      capture_status: "ok",
      directive_state: "none",
      last_directive: nil,
      next_action: %{action: "send-session", reason: "managed session", safety: "gated"},
      change: %{
        change: "same",
        needs_attention: false,
        work_state: "idle",
        previous_work_state: "idle",
        capture_status: "ok",
        previous_capture_status: "ok",
        changed_fields: [],
        observed_at: DateTime.to_iso8601(observed_at),
        elapsed_seconds: 60
      },
      repo: %{
        blockers: [],
        risks: [],
        branch: "main",
        dirty: false,
        ahead: 0,
        behind: 0
      },
      handoff: %{suggested_message: ""}
    }
  end
end
