defmodule JX.PortfolioSummaryTest do
  use ExUnit.Case, async: true

  alias JX.PortfolioSummary

  test "active sent work takes priority over blocked backlog in project next action" do
    blocked = profile("s-blocked", state: "blocked", prompt_status: "blocked")
    active = profile("s-active", state: "awaiting-observation", work_state: "running")

    summary =
      PortfolioSummary.build([], %{
        generated_at: DateTime.utc_now(),
        observed: false,
        observation_refresh: %{observed: false},
        profiles: [blocked, active],
        errors: []
      })

    assert [%{next_action: "observe sent work"}] = summary.projects
    assert summary.totals.blocked_sessions == 1
    assert summary.totals.awaiting_observation == 1
    assert summary.totals.running_sessions == 1
  end

  test "completed pushed commits do not look like pending commit work" do
    completed =
      profile("s-complete",
        state: "blocked",
        prompt_status: "blocked",
        notes: "Commit f2ec8aa6 pushed. Test passed; Coverage Report passed."
      )

    summary =
      PortfolioSummary.build([], %{
        generated_at: DateTime.utc_now(),
        observed: false,
        observation_refresh: %{observed: false},
        profiles: [completed],
        errors: []
      })

    assert [%{next_action: "resolve blocked session before prompting"}] = summary.projects
  end

  test "parked profiles are counted separately from urgent blocked sessions" do
    parked =
      profile("s-parked",
        state: "parked",
        lifecycle_status: "parked",
        prompt_status: "blocked"
      )

    summary =
      PortfolioSummary.build([], %{
        generated_at: DateTime.utc_now(),
        observed: false,
        observation_refresh: %{observed: false},
        profiles: [parked],
        errors: []
      })

    assert summary.totals.blocked_sessions == 0
    assert summary.totals.parked_sessions == 1
    assert summary.totals.blocked_reasons == %{"parked" => 1}
    assert [%{blocked_total: 0, parked_total: 1, next_action: "track"}] = summary.projects
  end

  test "registered project paths group unlabeled sessions into the project" do
    unlabeled =
      profile("s-path",
        state: "tracking",
        prompt_status: "none",
        project: "",
        current_path: "/srv/repos/saysure/subdir",
        repo_root: "/srv/repos/saysure"
      )

    summary =
      PortfolioSummary.build(
        [
          %{
            name: "saysure",
            slug: "saysure",
            host: %{name: "build-1", transport: "ssh", ssh_target: "", workspace_path: "/srv"},
            repo_path: "/srv/repos/saysure"
          }
        ],
        %{
          generated_at: DateTime.utc_now(),
          observed: false,
          observation_refresh: %{observed: false},
          profiles: [unlabeled],
          errors: []
        }
      )

    assert [%{name: "saysure", sessions_total: 1, registered: true}] = summary.projects
  end

  defp profile(ref, opts) do
    state = Keyword.fetch!(opts, :state)
    work_state = Keyword.get(opts, :work_state, "waiting")
    prompt_status = Keyword.get(opts, :prompt_status, "sent")
    lifecycle_status = Keyword.get(opts, :lifecycle_status, "active")
    project = Keyword.get(opts, :project, "example-project")
    current_path = Keyword.get(opts, :current_path, "/repo")
    repo_root = Keyword.get(opts, :repo_root, "/repo")

    %{
      ref: ref,
      session: %{
        project: project,
        host: "local",
        current_path: current_path,
        control_mode: "managed",
        can_direct: true,
        agent_name: "claude"
      },
      comparison: %{
        state: state,
        actual_summary: "",
        repo_blockers: [],
        repo_risks: []
      },
      next_prompt: %{status: prompt_status, text: ""},
      actual: %{
        work_state: work_state,
        repo: %{root: repo_root, branch: "feature/test"}
      },
      planned: %{
        summary: "",
        objective: "",
        strategy: "",
        notes: Keyword.get(opts, :notes, ""),
        prompt_status: prompt_status,
        lifecycle_status: lifecycle_status
      },
      next_step: ""
    }
  end
end
