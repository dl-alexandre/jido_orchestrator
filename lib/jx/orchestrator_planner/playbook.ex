defmodule JX.OrchestratorPlanner.Playbook do
  @moduledoc """
  Behaviour for project-specific continuation playbooks.

  A playbook recognizes a known-safe continuation pattern in a completed
  agent report and supplies the next prompt for it. Playbooks are how
  project-specific safe-prompt knowledge is registered with the planner
  without baking it into the planner core.

  Configure the active list via:

      config :jx, :planner_playbooks, [MyApp.Playbooks.Foo]

  Each playbook is consulted in order; the first whose `match?/1` returns
  `true` supplies the prompt via `prompt_for/1`. The planner's safe-prompt
  allowlist is augmented with each playbook's `safe_pattern/0` so the
  planner accepts prompts the playbook would emit.

  A playbook should never widen the orchestrator's risk surface. The
  planner still applies its own risky-pattern denylist after the playbook
  produces a prompt; a playbook returning a prompt that contains a risky
  term will still be rejected by the planner safety gate.
  """

  @doc "Return true if this playbook can handle the given observation output."
  @callback match?(output :: String.t()) :: boolean()

  @doc """
  Build the continuation prompt and reason for the matched output.

  Returns `{:ok, prompt, reason}` for a usable continuation, `:error`
  otherwise (the planner falls through to the generic next-step path).
  """
  @callback prompt_for(output :: String.t()) :: {:ok, String.t(), String.t()} | :error

  @doc """
  Optional extra safe-prompt regex this playbook contributes.

  The planner's safety gate accepts a prompt if it matches any of the
  baseline safe patterns or any playbook-supplied safe pattern. Return
  `nil` to add nothing.
  """
  @callback safe_pattern() :: Regex.t() | nil

  @optional_callbacks safe_pattern: 0
end
