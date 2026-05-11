defmodule JX.DelegationsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JX.CLI
  alias JX.Delegations
  alias JX.Delegations.Delegation
  alias JX.Repo

  setup do
    Repo.delete_all(Delegation)
    :ok
  end

  test "creates lists renders and completes delegation packets" do
    assert {:ok, %Delegation{} = delegation} =
             Delegations.create(%{
               title: "Fix PR CI",
               brief: "Inspect failing test logs and patch the smallest relevant code path.",
               project: "example-project",
               ref: "s-ci",
               owner: "foreground",
               agent_kind: "worker",
               priority: 7,
               context: ["PR #461 Test job failed"],
               constraints: ["Do not touch unrelated files"],
               acceptance: ["Focused tests pass"],
               verification: ["mix test test/one/scale_test.exs"],
               write_paths: ["lib/one/scale.ex"],
               forbidden_paths: ["lib/one/dashboard.ex"]
             })

    assert delegation.delegation_id =~ "dlg-"
    assert delegation.status == "queued"
    assert Jason.decode!(delegation.context) == ["PR #461 Test job failed"]
    assert Jason.decode!(delegation.write_paths) == ["lib/one/scale.ex"]
    assert Jason.decode!(delegation.forbidden_paths) == ["lib/one/dashboard.ex"]
    assert Jason.decode!(delegation.lint_warnings) == []

    assert [listed] = Delegations.list(status: "queued", project: "example-project")
    assert listed.delegation_id == delegation.delegation_id

    assert {:ok, packet} = Delegations.brief_packet(delegation.delegation_id)
    assert packet =~ "Fix PR CI"
    assert packet =~ "Do not touch unrelated files"
    assert packet =~ "Write Paths:"
    assert packet =~ "lib/one/scale.ex"

    assert {:ok, preflight} = Delegations.preflight(delegation.delegation_id)
    assert preflight.status == "ready"
    assert preflight.warnings == []

    assert {:ok, running} = Delegations.start(delegation.delegation_id, owner: "worker-1")
    assert running.status == "running"
    assert running.owner == "worker-1"
    assert %DateTime{} = running.claimed_at

    assert {:ok, completed} =
             Delegations.complete(delegation.delegation_id,
               worker_summary: "Patched scale partition creation.",
               verification: ["20 focused tests passed"],
               artifacts: ["lib/one/scale.ex"],
               residual_risks: ["full suite not rerun"],
               evidence: [
                 %{
                   command: "mix test test/one/scale_test.exs",
                   cwd: "/repo",
                   exit_status: 0,
                   kind: "focused",
                   output_excerpt: "20 tests, 0 failures",
                   artifacts: ["test/one/scale_test.exs"],
                   risks: ["only focused tests"]
                 }
               ]
             )

    assert completed.status == "completed"
    assert completed.worker_summary == "Patched scale partition creation."
    assert Jason.decode!(completed.artifacts) == ["lib/one/scale.ex", "test/one/scale_test.exs"]

    assert [
             %{
               "command" => "mix test test/one/scale_test.exs",
               "cwd" => "/repo",
               "exit_status" => 0,
               "status" => "passed",
               "output_excerpt" => "20 tests, 0 failures"
             }
           ] = Jason.decode!(completed.evidence)

    assert Jason.decode!(completed.residual_risks) == [
             "full suite not rerun",
             "only focused tests"
           ]

    assert %DateTime{} = completed.completed_at

    assert %{open_total: 0, by_status: %{"completed" => 1}} = Delegations.summary()

    assert {:ok, review} = Delegations.review(delegation.delegation_id)
    assert review.decision == "revise"
    assert "residual risks need foreground review" in review.warnings
    assert "artifacts include paths outside declared write ownership" in review.warnings
    assert review.evidence.passed == 1
    assert review.ownership.outside_write_paths == ["test/one/scale_test.exs"]

    completed_summary = Delegations.delegation_summary(completed)
    assert completed_summary.review.decision == "revise"
  end

  test "review card accepts clean completed delegation evidence" do
    assert {:ok, delegation} =
             Delegations.create(%{
               title: "Clean packet",
               brief: "Patch one file.",
               project: "saysure",
               ref: "s-clean",
               context: ["Need fix"],
               constraints: ["Only touch owned file"],
               acceptance: ["Focused tests pass"],
               verification: ["mix test"],
               write_paths: ["lib/example.ex"]
             })

    assert {:ok, completed} =
             Delegations.complete(delegation.delegation_id,
               worker_summary: "Patched owned file.",
               artifacts: ["lib/example.ex"],
               evidence: [
                 %{
                   command: "mix test",
                   cwd: "/repo",
                   exit_status: 0,
                   kind: "focused",
                   output_excerpt: "1 test, 0 failures"
                 }
               ]
             )

    assert {:ok, review} = Delegations.review(completed.delegation_id)
    assert review.decision == "accept"
    assert review.summary == "ready to accept"
    assert review.warnings == []

    assert [queued_review] = Delegations.list_reviews()
    assert queued_review.delegation_id == completed.delegation_id

    assert {:ok, decided} =
             Delegations.decide_review(completed.delegation_id, "accept",
               summary: "Accepted into foreground changes.",
               reviewer: "foreground"
             )

    assert decided.integration_status == "accepted"
    assert decided.integration_summary == "Accepted into foreground changes."
    assert decided.reviewed_by == "foreground"
    assert %DateTime{} = decided.reviewed_at
    completed_id = completed.delegation_id
    assert Delegations.list_reviews() == []
    assert [%{delegation_id: ^completed_id}] = Delegations.list_reviews(integration_status: "all")
  end

  test "review decision requires completed delegation output" do
    assert {:ok, delegation} =
             Delegations.create(%{
               title: "Queued packet",
               brief: "Do not decide yet.",
               project: "saysure",
               ref: "s-queued",
               context: ["Needs worker output"],
               constraints: ["Wait for completion"],
               acceptance: ["Worker completes"],
               verification: ["mix test"]
             })

    assert {:error, {:delegation_not_completed, "queued"}} =
             Delegations.decide_review(delegation.delegation_id, "hold",
               summary: "Too early.",
               reviewer: "foreground"
             )
  end

  test "timing summary learns completed runtimes and flags active work" do
    assert {:ok, completed_packet} =
             Delegations.create(%{
               title: "Completed timing packet",
               brief: "Measure completed work.",
               project: "saysure",
               ref: "s-timing-done",
               context: ["Need timing"],
               constraints: ["Keep focused"],
               acceptance: ["Tests pass"],
               verification: ["mix test"],
               agent_kind: "codex"
             })

    assert {:ok, running_packet} =
             Delegations.create(%{
               title: "Running timing packet",
               brief: "Measure active work.",
               project: "saysure",
               ref: "s-timing-run",
               context: ["Need timing"],
               constraints: ["Keep focused"],
               acceptance: ["Tests pass"],
               verification: ["mix test"],
               agent_kind: "codex"
             })

    assert {:ok, _running} = Delegations.start(completed_packet.delegation_id, owner: "worker-1")

    assert {:ok, completed} =
             Delegations.complete(completed_packet.delegation_id,
               worker_summary: "Finished.",
               artifacts: [],
               evidence: [
                 %{
                   command: "mix test",
                   cwd: "/repo",
                   exit_status: 0
                 }
               ]
             )

    assert {:ok, _running} = Delegations.start(running_packet.delegation_id, owner: "worker-2")

    timing = Delegations.timing_summary(agent_kind: "codex")

    assert timing.samples_total == 1
    assert timing.global.samples == 1
    assert timing.by_agent_kind["codex"].samples == 1
    assert timing.active.running == 1
    assert [%{delegation_id: running_id, status: "running"}] = timing.active.items
    assert running_id == running_packet.delegation_id
    assert timing.pending_reviews.total == 1
    assert [%{delegation_id: completed_id, decision: "accept"}] = timing.pending_reviews.items
    assert completed_id == completed.delegation_id
    assert timing.assignment.recommended_new_starts == 0
    assert timing.assignment.reason =~ "integrate completed delegation reviews"
  end

  test "review card rejects forbidden artifacts and failed evidence" do
    assert {:ok, delegation} =
             Delegations.create(%{
               title: "Bad packet",
               brief: "Patch one file.",
               project: "saysure",
               ref: "s-bad",
               context: ["Need fix"],
               constraints: ["Do not touch forbidden file"],
               acceptance: ["Focused tests pass"],
               verification: ["mix test"],
               write_paths: ["lib/example.ex"],
               forbidden_paths: ["lib/secret.ex"]
             })

    assert {:ok, completed} =
             Delegations.complete(delegation.delegation_id,
               worker_summary: "Patched files.",
               artifacts: ["lib/example.ex", "lib/secret.ex"],
               evidence: [
                 %{
                   command: "mix test",
                   cwd: "/repo",
                   exit_status: 1,
                   kind: "focused",
                   output_excerpt: "1 failure"
                 }
               ]
             )

    assert {:ok, review} = Delegations.review(completed.delegation_id)
    assert review.decision == "reject"
    assert "one or more evidence commands failed" in review.warnings
    assert "artifacts include forbidden paths" in review.warnings
    assert review.ownership.forbidden_touches == ["lib/secret.ex"]
  end

  test "review canonicalizes parent segments before ownership checks" do
    assert {:ok, delegation} =
             Delegations.create(%{
               title: "Traversal packet",
               brief: "Patch one file.",
               project: "saysure",
               ref: "s-traversal",
               context: ["Need fix"],
               constraints: ["Do not touch forbidden file"],
               acceptance: ["Focused tests pass"],
               verification: ["mix test"],
               write_paths: ["lib/owned"],
               forbidden_paths: ["lib/secret.ex"]
             })

    assert {:ok, completed} =
             Delegations.complete(delegation.delegation_id,
               worker_summary: "Patched files.",
               artifacts: ["lib/owned/../secret.ex"],
               evidence: [
                 %{
                   command: "mix test",
                   cwd: "/repo",
                   exit_status: 0,
                   kind: "focused",
                   output_excerpt: "1 test, 0 failures"
                 }
               ]
             )

    assert {:ok, review} = Delegations.review(completed.delegation_id)
    assert review.decision == "reject"
    assert "artifacts include forbidden paths" in review.warnings
    assert review.ownership.forbidden_touches == ["lib/owned/../secret.ex"]
  end

  test "CLI preserves repeated delegation evidence switches" do
    create_output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "delegate",
                   "create",
                   "--title",
                   "Parallel worker packet",
                   "--brief",
                   "Handle the bounded task.",
                   "--project",
                   "saysure",
                   "--ref",
                   "s-cli",
                   "--context",
                   "first context",
                   "--context",
                   "second context",
                   "--constraint",
                   "first constraint",
                   "--constraint",
                   "second constraint",
                   "--acceptance",
                   "first acceptance",
                   "--acceptance",
                   "second acceptance",
                   "--verify",
                   "first verify",
                   "--verify",
                   "second verify",
                   "--write",
                   "lib/example.ex",
                   "--write",
                   "test/example_test.exs",
                   "--forbid",
                   "lib/other.ex",
                   "--forbid",
                   "test/other_test.exs",
                   "--json"
                 ])
      end)

    created = Jason.decode!(create_output)

    assert created["context"] == ["first context", "second context"]
    assert created["constraints"] == ["first constraint", "second constraint"]
    assert created["acceptance"] == ["first acceptance", "second acceptance"]
    assert created["verification"] == ["first verify", "second verify"]
    assert created["write_paths"] == ["lib/example.ex", "test/example_test.exs"]
    assert created["forbidden_paths"] == ["lib/other.ex", "test/other_test.exs"]
    assert created["lint_warnings"] == []

    delegation_id = created["delegation_id"]

    complete_output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "delegate",
                   "complete",
                   delegation_id,
                   "--summary",
                   "Finished.",
                   "--verify",
                   "focused tests",
                   "--verify",
                   "full retry",
                   "--artifact",
                   "lib/example.ex",
                   "--artifact",
                   "test/example_test.exs",
                   "--risk",
                   "full suite not rerun",
                   "--evidence-command",
                   "mix test test/example_test.exs",
                   "--evidence-cwd",
                   "/repo",
                   "--evidence-exit",
                   "0",
                   "--evidence-kind",
                   "focused",
                   "--evidence-output",
                   "2 tests, 0 failures",
                   "--json"
                 ])
      end)

    completed = Jason.decode!(complete_output)

    assert completed["status"] == "completed"
    assert completed["verification"] == ["focused tests", "full retry"]
    assert completed["artifacts"] == ["lib/example.ex", "test/example_test.exs"]
    assert completed["residual_risks"] == ["full suite not rerun"]
    assert completed["review"]["decision"] == "hold"

    assert [
             %{
               "command" => "mix test test/example_test.exs",
               "cwd" => "/repo",
               "exit_status" => 0,
               "kind" => "focused",
               "status" => "passed",
               "output_excerpt" => "2 tests, 0 failures"
             }
           ] = completed["evidence"]
  end

  test "CLI adds command evidence before completion" do
    assert {:ok, delegation} =
             Delegations.create(%{
               title: "Evidence packet",
               brief: "Record exact verification.",
               project: "saysure",
               ref: "s-evidence",
               context: ["Worker reported tests"],
               constraints: ["Only record evidence"],
               acceptance: ["Evidence is structured"],
               verification: ["mix test"],
               write_paths: ["lib/example.ex"]
             })

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "delegate",
                   "evidence",
                   delegation.delegation_id,
                   "--command",
                   "mix test",
                   "--cwd",
                   "/repo",
                   "--exit",
                   "2",
                   "--kind",
                   "full",
                   "--output",
                   "1 failure",
                   "--artifact",
                   "test/failure_test.exs",
                   "--risk",
                   "failure still open",
                   "--json"
                 ])
      end)

    updated = Jason.decode!(output)

    assert [%{"status" => "failed", "exit_status" => 2, "command" => "mix test"}] =
             updated["evidence"]

    assert updated["artifacts"] == ["test/failure_test.exs"]
    assert updated["residual_risks"] == ["failure still open"]
  end

  test "CLI renders integration review cards" do
    assert {:ok, delegation} =
             Delegations.create(%{
               title: "Review CLI packet",
               brief: "Patch one file.",
               project: "saysure",
               ref: "s-review",
               context: ["Need fix"],
               constraints: ["Only touch owned file"],
               acceptance: ["Focused tests pass"],
               verification: ["mix test"],
               write_paths: ["lib/example.ex"]
             })

    assert {:ok, completed} =
             Delegations.complete(delegation.delegation_id,
               worker_summary: "Patched owned file.",
               artifacts: ["lib/example.ex"],
               evidence: [
                 %{
                   command: "mix test",
                   cwd: "/repo",
                   exit_status: 0
                 }
               ]
             )

    output =
      capture_io(fn ->
        assert :ok = CLI.run(["delegate", "review", completed.delegation_id, "--json"])
      end)

    review = Jason.decode!(output)
    assert review["decision"] == "accept"
    assert review["evidence"]["passed"] == 1

    reviews_output =
      capture_io(fn ->
        assert :ok = CLI.run(["delegate", "reviews", "--json"])
      end)

    assert %{"reviews" => [%{"delegation_id" => delegation_id}]} = Jason.decode!(reviews_output)
    assert delegation_id == completed.delegation_id

    decide_output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "delegate",
                   "decide",
                   completed.delegation_id,
                   "--decision",
                   "accept",
                   "--summary",
                   "Accepted.",
                   "--reviewer",
                   "foreground",
                   "--json"
                 ])
      end)

    decided = Jason.decode!(decide_output)
    assert decided["integration_status"] == "accepted"
    assert decided["integration_summary"] == "Accepted."
    assert decided["reviewed_by"] == "foreground"

    after_decide_output =
      capture_io(fn ->
        assert :ok = CLI.run(["delegate", "reviews", "--json"])
      end)

    assert %{"reviews" => []} = Jason.decode!(after_decide_output)

    timing_output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "delegate",
                   "timing",
                   "--project",
                   "saysure",
                   "--target-parallel",
                   "2",
                   "--json"
                 ])
      end)

    timing = Jason.decode!(timing_output)
    assert timing["samples_total"] == 1
    assert timing["global"]["samples"] == 1
    assert timing["assignment"]["target_parallel"] == 2
  end

  test "preflight warns on underspecified write-capable packets" do
    assert {:ok, delegation} =
             Delegations.create(%{
               title: "Vague fix",
               brief: "Fix the thing and push the branch.",
               agent_kind: "worker"
             })

    assert {:ok, preflight} = Delegations.preflight(delegation.delegation_id)

    assert preflight.status == "warning"
    assert :project in preflight.missing
    assert :write_paths in preflight.missing
    assert "packet missing project" in preflight.warnings
    assert "write-capable delegation missing --write ownership paths" in preflight.warnings

    assert Enum.any?(
             preflight.warnings,
             &String.contains?(&1, "foreground review required")
           )
  end

  test "start blocks when active delegations overlap write ownership" do
    assert {:ok, first} =
             Delegations.create(%{
               title: "Scale partition fix",
               brief: "Patch scale partition creation.",
               project: "example-project",
               ref: "s-scale",
               context: ["CI failed"],
               constraints: ["Only touch scale files"],
               acceptance: ["Scale tests pass"],
               verification: ["mix test test/one/scale_test.exs"],
               write_paths: ["lib/one/scale.ex"]
             })

    assert {:ok, _running} = Delegations.start(first.delegation_id, owner: "worker-1")

    assert {:ok, second} =
             Delegations.create(%{
               title: "Scale cleanup",
               brief: "Refactor scale helper.",
               project: "example-project",
               ref: "s-scale-2",
               context: ["Cleanup requested"],
               constraints: ["Only touch scale files"],
               acceptance: ["Scale tests pass"],
               verification: ["mix test test/one/scale_test.exs"],
               write_paths: ["lib/one"]
             })

    assert {:ok, preflight} = Delegations.preflight(second.delegation_id)
    assert preflight.status == "blocked"

    assert [%{delegation_id: first_id, path: "lib/one", conflicting_path: "lib/one/scale.ex"}] =
             preflight.conflicts

    assert first_id == first.delegation_id

    assert {:error, {:delegation_conflict, report}} =
             Delegations.start(second.delegation_id, owner: "worker-2")

    assert report.status == "blocked"
  end

  test "preflight canonicalizes parent segments before detecting write conflicts" do
    assert {:ok, first} =
             Delegations.create(%{
               title: "Secret fix",
               brief: "Patch secret file.",
               project: "example-project",
               ref: "s-secret",
               context: ["CI failed"],
               constraints: ["Only touch owned files"],
               acceptance: ["Tests pass"],
               verification: ["mix test"],
               write_paths: ["lib/one/secret.ex"]
             })

    assert {:ok, _running} = Delegations.start(first.delegation_id, owner: "worker-1")

    assert {:ok, second} =
             Delegations.create(%{
               title: "Traversal cleanup",
               brief: "Patch file through a normalized path.",
               project: "example-project",
               ref: "s-secret-2",
               context: ["Cleanup requested"],
               constraints: ["Only touch owned files"],
               acceptance: ["Tests pass"],
               verification: ["mix test"],
               write_paths: ["lib/one/owned/../secret.ex"]
             })

    assert {:ok, preflight} = Delegations.preflight(second.delegation_id)
    assert preflight.status == "blocked"

    assert [
             %{
               delegation_id: first_id,
               path: "lib/one/owned/../secret.ex",
               conflicting_path: "lib/one/secret.ex"
             }
           ] = preflight.conflicts

    assert first_id == first.delegation_id
  end
end
