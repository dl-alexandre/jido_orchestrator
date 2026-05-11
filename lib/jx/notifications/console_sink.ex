defmodule JX.Notifications.ConsoleSink do
  @moduledoc """
  Console/log notification sink.

  This sink uses Logger so escript users get operator-visible messages through
  the configured console backend without coupling approval routing to stdout.
  """

  @behaviour JX.Notifications.Sink

  require Logger

  @impl true
  def deliver(event, _opts \\ []) when is_map(event) do
    level = logger_level(Map.get(event, :severity, "info"))
    Logger.log(level, message(event))
    :ok
  end

  defp logger_level("critical"), do: :error
  defp logger_level("warning"), do: :warning
  defp logger_level("notice"), do: :info
  defp logger_level(_severity), do: :info

  defp message(event) do
    approval = Map.get(event, :approval, %{})

    [
      "[jx]",
      Map.get(event, :event, "notification"),
      Map.get(event, :severity, "info"),
      Map.get(approval, :approval_id, ""),
      Map.get(approval, :workspace_id, ""),
      Map.get(approval, :kind, ""),
      Map.get(event, :summary, "")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end
end
