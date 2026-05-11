defmodule JX.Workspace.RepoGateTest do
  use ExUnit.Case, async: true

  alias JX.Workspace.RepoGate

  test "trusted high confidence repo with no drift and auth ok is allowed" do
    assert RepoGate.evaluate(repo_state()) == %{
             eligible: true,
             status: "allowed",
             reasons: [],
             required_fixes: []
           }
  end

  test "degraded trust is blocked" do
    gate = RepoGate.evaluate(repo_state(trust_status: "degraded"))

    refute gate.eligible
    assert gate.status == "blocked"
    assert "degraded_auth" in gate.reasons
  end

  test "partial confidence is blocked" do
    gate = RepoGate.evaluate(repo_state(confidence: "partial"))

    refute gate.eligible
    assert gate.status == "blocked"
    assert "partial_confidence" in gate.reasons
  end

  test "drifted repo is blocked" do
    gate = RepoGate.evaluate(repo_state(drift: %{status: "dirty"}))

    refute gate.eligible
    assert gate.status == "blocked"
    assert "dirty_drift" in gate.reasons
  end

  test "fetch failure is blocked" do
    gate = RepoGate.evaluate(repo_state(auth: %{fetch_allowed: "failed"}))

    refute gate.eligible
    assert gate.status == "blocked"
    assert "fetch_failed" in gate.reasons
  end

  test "push failure is blocked" do
    gate = RepoGate.evaluate(repo_state(auth: %{push_allowed: "failed"}))

    refute gate.eligible
    assert gate.status == "blocked"
    assert "push_failed" in gate.reasons
  end

  test "unknown reconciliation is blocked" do
    gate = RepoGate.evaluate(repo_state(reconciliation_status: "unknown"))

    refute gate.eligible
    assert gate.status == "blocked"
    assert "unknown_reconciliation" in gate.reasons
  end

  test "string-keyed repo_state maps are evaluated the same way" do
    state =
      repo_state()
      |> Jason.encode!()
      |> Jason.decode!()

    assert RepoGate.evaluate(state).eligible
  end

  defp repo_state(overrides \\ []) do
    base = %{
      reconciliation_status: "reconciled",
      trust_status: "trusted",
      confidence: "high",
      drift: %{status: "none"},
      auth: %{
        fetch_allowed: "ok",
        push_allowed: "ok",
        api_allowed: "unknown"
      }
    }

    Enum.reduce(overrides, base, fn
      {:auth, auth}, state -> put_in(state, [:auth], Map.merge(state.auth, auth))
      {:drift, drift}, state -> put_in(state, [:drift], Map.merge(state.drift, drift))
      {key, value}, state -> Map.put(state, key, value)
    end)
  end
end
