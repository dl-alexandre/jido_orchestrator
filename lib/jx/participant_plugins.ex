defmodule JX.ParticipantPlugins do
  @moduledoc """
  Registry for bundled realtime participant plugins.

  Participant plugins are synchronous meeting or voice surfaces that can feed
  structured handoffs, artifacts, and follow-up work into the orchestration
  model without bypassing `JX.Workspace`.
  """

  alias JX.ParticipantPlugins.GoogleMeet

  @plugins [GoogleMeet]

  @doc """
  Lists bundled participant plugin metadata.
  """
  def list do
    Enum.map(@plugins, & &1.plugin())
  end

  @doc """
  Fetches a bundled participant plugin by id.
  """
  def get(id) do
    Enum.find(list(), &(&1.id == id))
  end
end
