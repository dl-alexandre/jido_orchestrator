defmodule JX.SafeActions.Registry do
  @moduledoc """
  Registry of supported safe-action kinds.

  The registry is intentionally explicit. Adding an action kind requires adding
  a module here and extending the contract tests.
  """

  alias JX.SafeActions.Kinds.{AcknowledgeApproval, RerunDevIDECommand}

  @default_kind "rerun_devide_command"
  @modules [RerunDevIDECommand, AcknowledgeApproval]

  def default_kind, do: @default_kind
  def modules, do: @modules
  def kinds, do: Enum.map(@modules, & &1.kind())

  def fetch(kind) when is_binary(kind) do
    case Enum.find(@modules, &(&1.kind() == kind)) do
      nil -> {:error, {:unsupported_safe_action, kind}}
      module -> {:ok, module}
    end
  end

  def fetch(kind), do: {:error, {:unsupported_safe_action, kind}}

  def fetch!(kind) do
    case fetch(kind) do
      {:ok, module} ->
        module

      {:error, reason} ->
        raise ArgumentError, "unsupported safe action kind: #{inspect(reason)}"
    end
  end
end
