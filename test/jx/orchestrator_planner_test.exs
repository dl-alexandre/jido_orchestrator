defmodule JX.OrchestratorPlannerTest do
  use ExUnit.Case, async: true

  alias JX.OrchestratorPlanner

  test "plans a safe Plantings nil-guard continuation" do
    output = """
    Current Status
    Plantings tests added and targeted suite is green.

    Next concrete step
    Fix the Plantings nil-guard bug, mirroring the CropPlans fix.
    Run mix format and mix test test/one/farms/plantings_test.exs.
    """

    assert {:ok, plan} = OrchestratorPlanner.plan(profile(), observation(output))
    assert plan.safety == "safe"
    assert plan.prompt_status == "ready"
    assert plan.reason == "continue known Plantings nil-guard fix"
    assert plan.prompt =~ "ExampleApp.Plantings.validate_planting_consistency/2"
    assert plan.prompt =~ "Do not push"
  end

  test "plans a safe Farms Harvests coverage continuation" do
    output = """
    Next highest-value coverage target
    Recommend: ExampleApp.Harvests — same CRUD pattern, about 16 tests.
    """

    assert {:ok, plan} = OrchestratorPlanner.plan(profile(), observation(output))
    assert plan.reason == "continue next Farms coverage target"
    assert plan.prompt =~ "ExampleApp.Harvests"
    assert plan.prompt =~ "targeted Harvests tests"
  end

  test "plans from the response after the latest directive instead of stale transcript" do
    marker = "Proceed with the Plantings nil-guard fix next. Do not push."

    output = """
    Previous report
    Next concrete step
    Fix the Plantings nil-guard bug, mirroring the CropPlans fix.

    ❯ Proceed with the Plantings nil-guard fix next. Do not push.

    Status — Plantings nil-guard fix applied
    The bug is now closed.

    Next highest-value coverage target
    Recommend: ExampleApp.Harvests — same CRUD pattern, about 16 tests.
    """

    assert {:ok, plan} =
             OrchestratorPlanner.plan(
               profile(actual: %{work_state: "idle", last_directive: %{message: marker}}),
               observation(output)
             )

    assert plan.reason == "continue next Farms coverage target"
    assert plan.prompt =~ "ExampleApp.Harvests"
  end

  test "does not treat benign missing API key test warnings as manual credential work" do
    output = """
    Test results
    OpenWeatherMap API key not configured - using mock data

    Next highest-value coverage target
    Recommend: ExampleApp.Harvests — same CRUD pattern, about 16 tests.
    """

    assert {:ok, plan} = OrchestratorPlanner.plan(profile(), observation(output))
    assert plan.prompt =~ "ExampleApp.Harvests"
  end

  test "refuses risky completed reports" do
    output = """
    Next concrete step
    Push the current branch, merge PR #460, and deploy the release.
    """

    assert {:skip, "completed report includes manual-risk terms"} =
             OrchestratorPlanner.plan(profile(), observation(output))
  end

  test "classifies hold recommendations as manual profile holds" do
    output = """
    Status Report
    CI is not green because of an upstream environmental flake.

    Next concrete step
    Hold. Nothing in this PR can clear the Test failure. Wait for develop to go green.
    """

    assert {:ok, hold} = OrchestratorPlanner.hold(profile(), observation(output))
    assert hold.safety == "manual"
    assert hold.prompt_status == "blocked"
    assert hold.reason == "completed report recommends holding for a blocker"
  end

  test "classifies authorization requests as manual profile holds" do
    output = """
    Status — Harvests work paused; structural blocker discovered
    Each option requires user authorization since it touches production code.

    Pause here for direction:
    1. Authorize Option A
    2. Skip Harvests
    """

    assert {:ok, hold} = OrchestratorPlanner.hold(profile(), observation(output))
    assert hold.prompt_status == "blocked"
  end

  test "refuses API key setup work" do
    output = """
    Next concrete step
    Configure the production API key and rerun deployment.
    """

    assert {:skip, "completed report includes manual-risk terms"} =
             OrchestratorPlanner.plan(profile(), observation(output))
  end

  test "refuses sessions with active profile prompts" do
    assert {:skip, "profile already has an active prompt"} =
             OrchestratorPlanner.plan(
               profile(next_prompt: %{source: "profile", status: "sent"}),
               observation("Next concrete step\nFix the Plantings nil-guard bug.")
             )
  end

  defp profile(overrides \\ []) do
    next_prompt = Keyword.get(overrides, :next_prompt, %{source: "none", status: "none"})
    actual = Keyword.get(overrides, :actual, %{work_state: "idle"})

    %{
      ref: "s-test",
      session: %{control_mode: "managed", can_direct: true},
      actual: actual,
      planned: %{prompt_status: "none"},
      next_prompt: next_prompt
    }
  end

  defp observation(output) do
    %{snapshot: Jason.encode!(%{capture: %{output: output}}), summary: ""}
  end
end
