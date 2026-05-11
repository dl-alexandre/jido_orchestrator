defmodule JX.OperatorDirectives do
  @moduledoc """
  Compatibility boundary for audited instructions sent to tmux panes or tasks.

  These records are intentionally distinct from `Jido.Agent.Directive`, which is
  Jido's pure runtime effect description. Use this module in new code when the
  intent is a persisted operator or pane instruction.
  """

  defdelegate insert_instruction(attrs), to: JX.Directives, as: :insert_directive
  defdelegate list_instructions(opts \\ []), to: JX.Directives, as: :list_directives
end
