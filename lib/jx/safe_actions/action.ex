defmodule JX.SafeActions.Action do
  @moduledoc """
  Approval-gated safe action proposal.

  Execution is only available through `jx actions execute <id> --confirm`.
  """

  alias JX.SafeActions.Registry

  @enforce_keys [:approval_id, :workspace_id]
  defstruct kind: "rerun_devide_command",
            source: "devide",
            safety: "gated",
            dry_run_only: false,
            requires_confirmation: true,
            approval_id: nil,
            workspace_id: nil,
            command_id: "",
            db_isolation: "unknown",
            target_ref: "",
            reason: "approval-gated DevIDE command rerun proposal"

  @type t :: %__MODULE__{
          kind: String.t(),
          source: String.t(),
          safety: String.t(),
          dry_run_only: boolean(),
          requires_confirmation: boolean(),
          approval_id: String.t(),
          workspace_id: String.t(),
          command_id: String.t(),
          db_isolation: String.t(),
          target_ref: String.t(),
          reason: String.t()
        }

  def kinds, do: Registry.kinds()

  @spec recommendation_id(t()) :: String.t()
  def recommendation_id(%__MODULE__{} = action) do
    [
      action.kind,
      action.approval_id,
      action.workspace_id,
      action.command_id,
      action.target_ref
    ]
    |> fingerprint("safe")
  end

  @spec target(t()) :: String.t()
  def target(%__MODULE__{} = action),
    do: action.kind |> Registry.fetch!() |> apply(:target, [action])

  @spec would_do(t()) :: String.t()
  def would_do(%__MODULE__{} = action),
    do: action.kind |> Registry.fetch!() |> apply(:would_do, [action])

  @spec to_decision(t()) :: map()
  def to_decision(%__MODULE__{} = action) do
    %{
      id: recommendation_id(action),
      action: action.kind,
      safety: action.safety,
      ref: action.approval_id,
      target: target(action),
      reason: action.reason,
      result_summary: would_do(action),
      dry_run_only: action.dry_run_only,
      requires_confirmation: action.requires_confirmation,
      approval_id: action.approval_id,
      workspace_id: action.workspace_id,
      command_id: action.command_id,
      db_isolation: action.db_isolation,
      target_ref: action.target_ref,
      source: action.source,
      contract: action.kind |> Registry.fetch!() |> apply(:contract, [action])
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = action) do
    Map.take(action, [
      :kind,
      :source,
      :safety,
      :dry_run_only,
      :requires_confirmation,
      :approval_id,
      :workspace_id,
      :command_id,
      :db_isolation,
      :target_ref,
      :reason
    ])
    |> Map.put(:recommendation_id, recommendation_id(action))
    |> Map.put(:target, target(action))
    |> Map.put(:would_do, would_do(action))
  end

  defp fingerprint(values, prefix) do
    hash =
      values
      |> Enum.map(&to_string/1)
      |> Enum.intersperse(<<0>>)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    prefix <> "-" <> binary_part(hash, 0, 16)
  end
end
