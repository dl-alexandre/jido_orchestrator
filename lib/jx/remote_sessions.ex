defmodule JX.RemoteSessions do
  @moduledoc """
  Persistence for remote tmux sessions discovered through SSH pane probes.
  """

  import Ecto.Query

  alias JX.RemoteSessions.RemoteSessionObservation
  alias JX.Repo

  def record_probe(probe, recommendation) do
    sessions = Map.get(probe, :remote_sessions, [])

    Repo.transaction(fn ->
      Enum.map(sessions, fn session ->
        attrs = attrs_from_probe_session(probe, recommendation, session)

        %RemoteSessionObservation{}
        |> RemoteSessionObservation.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, observation} -> observation
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  def list_observations(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    RemoteSessionObservation
    |> maybe_filter_target(Keyword.get(opts, :target))
    |> maybe_filter_local_ref(Keyword.get(opts, :local_ref))
    |> order_by([observation], desc: observation.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def latest_by_identity(opts \\ []) do
    opts
    |> list_observations()
    |> Enum.uniq_by(&{&1.ssh_target, &1.tmux_server, &1.session_name})
  end

  defp attrs_from_probe_session(probe, recommendation, session) do
    %{
      local_ref: Map.get(recommendation, :ref, ""),
      ssh_target: Map.get(probe, :ssh_target, ""),
      registered_host: Map.get(probe, :registered_host, ""),
      tmux_server: Map.get(session, :server, ""),
      session_name: Map.get(session, :session, ""),
      created_at: Map.get(session, :created_at),
      attached: Map.get(session, :attached, 0),
      windows: Map.get(session, :windows, 0),
      current_path: Map.get(session, :current_path, ""),
      recommendation_id: Map.get(recommendation, :id, ""),
      probe_target: Map.get(probe, :target, "")
    }
  end

  defp maybe_filter_target(query, nil), do: query

  defp maybe_filter_target(query, target),
    do: where(query, [observation], observation.ssh_target == ^target)

  defp maybe_filter_local_ref(query, nil), do: query

  defp maybe_filter_local_ref(query, ref),
    do: where(query, [observation], observation.local_ref == ^ref)
end
