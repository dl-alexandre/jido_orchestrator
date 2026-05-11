defmodule JX.SafeActions.Kind do
  @moduledoc """
  Behaviour for one approval-gated safe-action kind.

  Safe-action kinds own their proposal policy, dry-run rendering, execution
  path, audit payloads, and recovery guidance. `JX.SafeActions` stays the
  ledger/orchestration shell.
  """

  alias JX.Approvals.Approval
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.SafeActions.Action

  @type context :: map()

  @callback kind() :: String.t()
  @callback propose(Approval.t(), context()) :: {:ok, Action.t()} | {:error, term()}
  @callback authorize(OrchestrationAction.t(), Approval.t(), context()) ::
              {:ok, Action.t(), term()} | {:error, term()}
  @callback dry_run(OrchestrationAction.t(), Action.t(), Approval.t(), context()) ::
              {:ok, map()} | {:error, term()}
  @callback execute(OrchestrationAction.t(), Action.t(), Approval.t(), context()) ::
              {:ok, map()} | {:error, term()}
  @callback target(Action.t()) :: String.t()
  @callback would_do(Action.t()) :: String.t()
  @callback contract(Action.t()) :: String.t()
  @callback expected_fields(Action.t()) :: map()
  @callback audit_payload(String.t(), OrchestrationAction.t(), Action.t(), map()) :: map()
  @callback recovery_guidance(OrchestrationAction.t(), [struct()], String.t()) :: String.t()
end
