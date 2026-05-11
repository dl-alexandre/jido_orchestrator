defmodule JX.Jido do
  @moduledoc """
  Jido runtime supervisor for jx orchestration actions.

  The runtime is intentionally thin: `JX.Workspace` remains the
  source of truth for hosts, sessions, directives, and safety policy.

  Jido actions are adapters over the Workspace API, not a parallel business
  layer. That design keeps autonomous and foreground paths comparable: the CLI,
  daemon loop, and future call or meeting surfaces all observe and mutate the
  same durable records.
  """

  use Jido, otp_app: :jx
end
