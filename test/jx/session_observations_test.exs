defmodule JX.SessionObservationsTest do
  use ExUnit.Case, async: false

  alias JX.Repo
  alias JX.SessionObservations
  alias JX.SessionObservations.SessionObservation

  setup do
    Repo.delete_all(SessionObservation)
    :ok
  end

  test "prune_missing_process_only removes stale process-only refs in scope" do
    old_process = insert_observation!(ref: "s-old-process", type: "ssh", host: "local")

    tmux_backed =
      insert_observation!(
        ref: "s-old-tmux",
        type: "ssh",
        host: "local",
        tmux_server: "default",
        session_name: "remote",
        window: 0,
        pane: 0
      )

    other_host = insert_observation!(ref: "s-other-host", type: "ssh", host: "remote")

    assert {1, nil} =
             SessionObservations.prune_missing_process_only([%{ref: "s-current"}],
               host: "local"
             )

    refute Repo.get(SessionObservation, old_process.id)
    assert Repo.get(SessionObservation, tmux_backed.id)
    assert Repo.get(SessionObservation, other_host.id)
  end

  test "prune_missing_process_only ignores non-process scopes" do
    observation = insert_observation!(ref: "s-old-process", type: "ssh", host: "local")

    assert {0, nil} =
             SessionObservations.prune_missing_process_only([%{ref: "s-current"}],
               host: "local",
               type: "agent"
             )

    assert Repo.get(SessionObservation, observation.id)
  end

  defp insert_observation!(attrs) do
    attrs =
      %{
        ref: "s-ref",
        host: "local",
        transport: "local",
        type: "ssh",
        state: "unmanaged",
        kind: "ssh",
        agent_name: "",
        task_id: "",
        tmux_server: "",
        session_name: "",
        window: nil,
        pane: nil,
        pid: 101,
        ssh_target: "build-1",
        work_state: "unobservable",
        capture_status: "skipped",
        summary: "",
        snapshot: "{}"
      }
      |> Map.merge(Map.new(attrs))

    %SessionObservation{}
    |> SessionObservation.changeset(attrs)
    |> Repo.insert!()
  end
end
