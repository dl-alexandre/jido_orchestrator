defmodule JX.OrchestratorPlanner.Playbooks.ExamplePlaybookTest do
  use ExUnit.Case, async: true

  alias JX.OrchestratorPlanner.Playbooks.ExamplePlaybook

  describe "match?/1" do
    test "matches a Harvests recommendation" do
      output = "Recommend: ExampleApp.Harvests — same CRUD pattern, about 16 tests."
      assert ExamplePlaybook.match?(output)
    end

    test "matches a Fields recommendation" do
      output = "Next highest-value coverage target — ExampleApp.Fields next."
      assert ExamplePlaybook.match?(output)
    end

    test "matches a Plantings nil-guard target" do
      output = "Next concrete step\nFix the Plantings nil-guard bug, mirroring CropPlans."
      assert ExamplePlaybook.match?(output)
    end

    test "does not match a closed Plantings nil-guard report" do
      output = """
      Status — Plantings nil-guard fix applied
      The bug is now closed.
      """

      refute ExamplePlaybook.match?(output)
    end

    test "does not match unrelated output" do
      refute ExamplePlaybook.match?("Status\nAll clear; nothing to do.")
      refute ExamplePlaybook.match?("")
      refute ExamplePlaybook.match?(nil)
    end
  end

  describe "prompt_for/1" do
    test "returns a Harvests continuation prompt" do
      output = "Recommend: ExampleApp.Harvests — same CRUD pattern."

      assert {:ok, prompt, "continue next Farms coverage target"} =
               ExamplePlaybook.prompt_for(output)

      assert prompt =~ "ExampleApp.Harvests"
      assert prompt =~ "Do not push"
    end

    test "returns a Fields continuation prompt" do
      output = "Recommend: ExampleApp.Fields next."

      assert {:ok, prompt, "continue next Farms coverage target"} =
               ExamplePlaybook.prompt_for(output)

      assert prompt =~ "ExampleApp.Fields"
    end

    test "returns the Plantings nil-guard prompt" do
      output = "Next concrete step\nFix the Plantings nil-guard bug."

      assert {:ok, prompt, "continue known Plantings nil-guard fix"} =
               ExamplePlaybook.prompt_for(output)

      assert prompt =~ "validate_planting_consistency/2"
    end

    test "returns :error for unrelated output" do
      assert ExamplePlaybook.prompt_for("nothing relevant") == :error
      assert ExamplePlaybook.prompt_for(nil) == :error
    end
  end

  describe "safe_pattern/0" do
    test "matches each ExampleApp module name" do
      pattern = ExamplePlaybook.safe_pattern()

      for module <- ~w(Harvests Fields Plantings CropPlans) do
        assert Regex.match?(pattern, "ExampleApp.#{module}")
      end
    end

    test "does not match unrelated module names" do
      pattern = ExamplePlaybook.safe_pattern()
      refute Regex.match?(pattern, "MyApp.Other")
      refute Regex.match?(pattern, "ExampleApp.Other")
    end
  end
end
