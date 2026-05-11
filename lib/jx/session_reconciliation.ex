defmodule JX.SessionReconciliation do
  @moduledoc """
  Reconciles local session refs with remote tmux observations.
  """

  def build(profile_report, remote_observations, opts \\ []) do
    limit = Keyword.get(opts, :limit, 25)
    profiles = profile_report.profiles
    profiles_by_ref = Map.new(profiles, &{&1.ref, &1})

    remote =
      remote_observations
      |> Enum.uniq_by(&remote_identity/1)
      |> Enum.map(&remote_item(&1, Map.get(profiles_by_ref, &1.local_ref)))

    local_refs = MapSet.new(Map.keys(profiles_by_ref))
    remote_refs = remote |> Enum.map(& &1.local_ref) |> Enum.reject(&(&1 == "")) |> MapSet.new()

    duplicate_paths =
      profiles
      |> Enum.group_by(&profile_path/1)
      |> Enum.reject(fn {path, grouped} -> path == "" or length(grouped) < 2 end)
      |> Enum.map(fn {path, grouped} ->
        %{
          path: path,
          refs: Enum.map(grouped, & &1.ref),
          projects: grouped |> Enum.map(&get_in(&1, [:session, :project])) |> Enum.uniq()
        }
      end)

    %{
      generated_at: DateTime.utc_now(),
      observed: profile_report.observed,
      observation_refresh: profile_report.observation_refresh,
      totals: %{
        local_sessions: length(profiles),
        remote_sessions: length(remote),
        matched_remote: Enum.count(remote, & &1.matched),
        orphan_remote: Enum.count(remote, &(not &1.matched)),
        local_without_remote: MapSet.size(MapSet.difference(local_refs, remote_refs)),
        duplicate_paths: length(duplicate_paths)
      },
      local_without_remote:
        profiles
        |> Enum.reject(&MapSet.member?(remote_refs, &1.ref))
        |> Enum.take(limit)
        |> Enum.map(&local_item/1),
      remote: Enum.take(remote, limit),
      orphan_remote: remote |> Enum.reject(& &1.matched) |> Enum.take(limit),
      duplicate_paths: Enum.take(duplicate_paths, limit),
      errors: profile_report.errors
    }
  end

  defp local_item(profile) do
    %{
      ref: profile.ref,
      project: get_in(profile, [:session, :project]) || "",
      type: get_in(profile, [:session, :type]) || "",
      kind: get_in(profile, [:session, :kind]) || "",
      pane: get_in(profile, [:session, :pane]) || "",
      path: profile_path(profile),
      state: get_in(profile, [:comparison, :state]) || "",
      prompt_status: get_in(profile, [:next_prompt, :status]) || "",
      next_step: profile.next_step || ""
    }
  end

  defp remote_item(observation, nil) do
    %{
      matched: false,
      local_ref: observation.local_ref || "",
      ssh_target: observation.ssh_target || "",
      registered_host: observation.registered_host || "",
      tmux_server: observation.tmux_server || "",
      session_name: observation.session_name || "",
      current_path: observation.current_path || "",
      windows: observation.windows,
      attached: observation.attached,
      observed_at: observation.inserted_at,
      local_project: "",
      local_state: ""
    }
  end

  defp remote_item(observation, profile) do
    observation
    |> remote_item(nil)
    |> Map.merge(%{
      matched: true,
      local_project: get_in(profile, [:session, :project]) || "",
      local_state: get_in(profile, [:comparison, :state]) || ""
    })
  end

  defp profile_path(profile), do: get_in(profile, [:session, :current_path]) || ""

  defp remote_identity(observation) do
    {
      observation.ssh_target || "",
      observation.tmux_server || "",
      observation.session_name || "",
      observation.current_path || ""
    }
  end
end
