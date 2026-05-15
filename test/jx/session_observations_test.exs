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

  describe "list_changes window-function semantics" do
    # First-time Ecto.Query.Builder subquery module loads can stall under
    # the cloud-synced filesystem in this dev environment (observed
    # repeatedly during /phx:perf #3, #4, #13). 180_000ms gives the FS
    # plenty of head-room; once modules are warm the assertions take
    # ~50ms. The actual logic under test doesn't care about the timeout.
    @describetag timeout: 180_000

    # Regression for /phx:perf #13 — the rewritten list_changes uses
    # ROW_NUMBER() OVER (PARTITION BY ref ORDER BY id DESC) to load only
    # the top two observations per ref. Older observations (rn >= 3) must
    # be ignored, and the diff fields must reflect the latest vs previous
    # transition, not latest vs oldest.
    test "selects top-2 per ref and diffs against the immediately previous row" do
      # Three observations for the same ref, in chronological order:
      #   - oldest: work_state "idle"
      #   - middle: work_state "blocked"  ← what diff should compare against
      #   - latest: work_state "running"
      _oldest = insert_observation!(ref: "s-top2", work_state: "idle")
      _middle = insert_observation!(ref: "s-top2", work_state: "blocked")
      _latest = insert_observation!(ref: "s-top2", work_state: "running")

      assert [change] = SessionObservations.list_changes(refs: ["s-top2"], limit: 5)

      assert change.work_state == "running"
      assert change.previous_work_state == "blocked"
      assert change.change == "changed"
      assert "work_state" in change.changed_fields
    end

    test "single observation per ref yields a 'new' change with no previous" do
      _only = insert_observation!(ref: "s-single", work_state: "running")

      assert [change] = SessionObservations.list_changes(refs: ["s-single"], limit: 5)

      assert change.change == "new"
      assert change.previous_work_state == nil
      assert change.changed_fields == []
    end
  end
end
