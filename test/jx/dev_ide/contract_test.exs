defmodule JX.DevIDE.ContractTest do
  use ExUnit.Case, async: true

  alias JX.DevIDE.{Portfolio, RunnerProtocol, Status}
  alias JXTest.Fixtures

  test "JX modules do not reference DevIDE internal modules" do
    offenders =
      "lib/jx"
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        path
        |> File.read!()
        |> forbidden_internal_reference?()
      end)

    assert offenders == []
  end

  test "portfolio classification is driven by JSON fixture payloads" do
    healthy =
      status_from_fixtures("status_healthy.json", "runs_success.json", "proposals_empty.json",
        audit: "audit_empty.json"
      )

    blocked =
      status_from_fixtures(
        "status_blocked_shared_stage.json",
        "runs_success.json",
        "proposals_empty.json",
        audit: "audit_policy_blocked.json"
      )

    review =
      status_from_fixtures("status_review.json", "runs_success.json", "proposals_conflict.json",
        audit: "audit_empty.json"
      )

    portfolio = Portfolio.from_statuses([healthy, blocked, review])

    assert Enum.map(portfolio.healthy, & &1.workspace.id) == ["healthy"]
    assert Enum.map(portfolio.blocked, & &1.workspace.id) == ["blocked"]
    assert Enum.map(portfolio.needs_review, & &1.workspace.id) == ["review"]
  end

  test "runner protocol v1 fixtures lock request and response envelopes" do
    assert RunnerProtocol.protocol() == "jx.runner.v1"

    assert Fixtures.devide_runner_payload("enqueue_request.json") == %{
             "command_id" => "test",
             "execution_protocol" => "jx.runner.v1",
             "jx_action_id" => "act-contract",
             "jx_assignment_id" => "asgn-contract",
             "jx_safe_action_kind" => "rerun_devide_command",
             "runner_requirements" => %{
               "branch_isolation" => "worktree",
               "host" => "host-a",
               "os" => "darwin",
               "repo" => "example-project",
               "tools" => ["mix", "git"]
             }
           }

    for fixture <- ~w(
          enqueue_response.json
          poll_response.json
          report_response.json
          complete_response.json
          fail_response.json
          replay_response.json
        ) do
      payload = Fixtures.devide_runner_payload(fixture)
      assert payload["protocol"] == RunnerProtocol.protocol()
    end

    assert Fixtures.devide_runner_payload("error_claim_rejected.json")["failure_class"] ==
             "claim_rejected"

    assert Fixtures.devide_runner_payload("error_report_rejected.json")["failure_class"] ==
             "report_rejected"
  end

  test "runner protocol rejects replay mismatches" do
    replay = Fixtures.devide_runner_payload("replay_response.json")

    assert :ok =
             RunnerProtocol.validate_replay(replay, %{
               assignment_id: "asgn-contract",
               workspace_id: "ws-contract",
               action_id: "act-contract"
             })

    assert {:error, {:replay_mismatch, :workspace_id}} =
             RunnerProtocol.validate_replay(replay, %{
               assignment_id: "asgn-contract",
               workspace_id: "other-workspace",
               action_id: "act-contract"
             })
  end

  defp status_from_fixtures(status_fixture, runs_fixture, proposals_fixture, opts) do
    Status.from_payload(
      Fixtures.devide_payload(status_fixture),
      Fixtures.devide_payload(runs_fixture),
      Fixtures.devide_payload(proposals_fixture),
      Fixtures.devide_payload(Keyword.fetch!(opts, :audit))
    )
  end

  defp forbidden_internal_reference?(source) do
    Enum.any?(
      [
        ~r/(^|[^\w.])(?:alias|import|require|use)\s+DevIDE(?:\.|\b)/,
        ~r/(^|[^\w.])(?:alias|import|require|use)\s+DevIdeWeb(?:\.|\b)/,
        ~r/(^|[^\w.])DevIDE\.[A-Z]/,
        ~r/(^|[^\w.])DevIdeWeb\.[A-Z]/
      ],
      &Regex.match?(&1, source)
    )
  end
end
