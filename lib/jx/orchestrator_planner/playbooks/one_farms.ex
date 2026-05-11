defmodule JX.OrchestratorPlanner.Playbooks.ExamplePlaybook do
  @moduledoc """
  Example continuation playbook demonstrating the `JX.OrchestratorPlanner.Playbook`
  interface.

  This playbook is registered by default in `config/config.exs` as a
  placeholder. Remove it from `:planner_playbooks` for projects that
  do not need this specific continuation logic, or replace it with
  your own playbook implementing `JX.OrchestratorPlanner.Playbook`.

  Recognised continuations:

    * Harvests coverage target — produces a focused-tests prompt
    * Fields coverage target — produces a focused-tests prompt
    * Plantings nil-guard fix — produces the canonical mirror-of-CropPlans
      prompt, suppressed once the report indicates the fix has been applied
  """

  @behaviour JX.OrchestratorPlanner.Playbook

  @impl true
  def match?(output) when is_binary(output) do
    harvests_target?(output) or fields_target?(output) or plantings_nil_guard_target?(output)
  end

  def match?(_output), do: false

  @impl true
  def prompt_for(output) when is_binary(output) do
    cond do
      harvests_target?(output) ->
        {:ok, farms_context_prompt("Harvests"), "continue next Farms coverage target"}

      fields_target?(output) ->
        {:ok, farms_context_prompt("Fields"), "continue next Farms coverage target"}

      plantings_nil_guard_target?(output) ->
        {:ok, plantings_nil_guard_prompt(), "continue known Plantings nil-guard fix"}

      true ->
        :error
    end
  end

  def prompt_for(_output), do: :error

  @impl true
  def safe_pattern, do: ~r/\bExampleApp\.(Harvests|Fields|Plantings|CropPlans)\b/

  defp harvests_target?(output) do
    Regex.match?(
      ~r/Recommend:\s+ExampleApp\.Harvests|Next highest-value.*ExampleApp\.Harvests/is,
      output
    )
  end

  defp fields_target?(output) do
    Regex.match?(
      ~r/Recommend:\s+ExampleApp\.Fields|Next highest-value.*ExampleApp\.Fields/is,
      output
    )
  end

  defp plantings_nil_guard_target?(output) do
    Regex.match?(~r/(Fix|Proceed with|Open:|Next concrete step).*Plantings.*nil-guard/is, output) and
      not Regex.match?(~r/Plantings nil-guard fix applied|bug is now closed/i, output)
  end

  defp plantings_nil_guard_prompt do
    "Proceed with the Plantings nil-guard fix next. Keep scope narrow and preserve unrelated dirty files. Mirror the CropPlans fix: update ExampleApp.Plantings.validate_planting_consistency/2 so missing farm_id, field_id, or crop_id returns :ok and lets schema validations handle required fields instead of crashing. Replace the Plantings test workaround with a regression test asserting Plantings.create_planting(%{}) returns {:error, changeset} with required-field errors. Run mix format on touched files, run mix test test/example_app/plantings_test.exs, and report changed files, test results, blockers, and the next highest-value target. Do not push."
  end

  defp farms_context_prompt(module_name) do
    "Proceed with ExampleApp.#{module_name} next. Keep scope narrow and preserve unrelated dirty files. Add focused context/submodule tests using the established example patterns. Prefer targeted coverage gaps over duplicate CRUD coverage. Run mix format on touched files, run the targeted #{module_name} tests, and report changed files, test results, coverage delta if checked, blockers, and the next highest-value target. Do not push."
  end
end
