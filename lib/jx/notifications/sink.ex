defmodule JX.Notifications.Sink do
  @moduledoc """
  Behaviour for operator-visible notification sinks.

  Sinks receive already-redacted event maps from `JX.Notifications.Router`.
  They must not mutate workspaces or call external control APIs.
  """

  @callback deliver(map(), keyword()) :: :ok | {:error, term()}
end
