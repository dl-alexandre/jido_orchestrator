defmodule JX.OperationPolicyTest do
  use ExUnit.Case, async: true

  alias JX.OperationPolicy

  test "authorizes ref-backed remote force probes" do
    assert :ok =
             OperationPolicy.authorize_gated(%{
               action: "capture-before-force-probe",
               kind: "remote",
               ref: "s-123"
             })
  end

  test "blocks force probes from attention recommendations" do
    assert {:skip, "force probe execution is only available for remote discovery recommendations"} =
             OperationPolicy.authorize_gated(%{
               action: "capture-before-force-probe",
               kind: "attention",
               ref: "s-123"
             })
  end

  test "blocks unlinked remote force probes" do
    assert {:skip, "force probe recommendation is not linked to a session ref"} =
             OperationPolicy.authorize_gated(%{
               action: "capture-before-force-probe",
               kind: "remote",
               ref: ""
             })
  end

  test "blocks unsupported gated actions" do
    assert {:skip, "gated execution for this action is not implemented"} =
             OperationPolicy.authorize_gated(%{action: "send-session", kind: "attention"})
  end

  test "safety tiers describe automation boundaries" do
    tiers = OperationPolicy.safety_tiers()

    assert Enum.map(tiers, & &1.id) == ~w(inspect safe gated manual held-release)
    assert Enum.find(tiers, &(&1.id == "gated")).confirmation == "execute-required"
    assert Enum.find(tiers, &(&1.id == "held-release")).autonomy == "operator-required"
  end

  test "directive policy requires managed or task ownership" do
    assert {:error,
            {:directive_policy_denied,
             "session is not managed; mark it managed or adopt it before sending"}} =
             OperationPolicy.authorize_directive(
               %{type: "agent", control_mode: "uncontrolled"},
               %{status: "ok"}
             )

    assert :ok =
             OperationPolicy.authorize_directive(
               %{type: "agent", control_mode: "managed"},
               %{status: "ok"}
             )
  end

  test "directive policy blocks protected sessions and stale captures" do
    assert {:error, {:directive_policy_denied, "session is protected"}} =
             OperationPolicy.authorize_directive(
               %{type: "agent", control_mode: "protected"},
               %{status: "ok"}
             )

    assert {:error, {:directive_policy_denied, "fresh capture required before sending"}} =
             OperationPolicy.authorize_directive(
               %{type: "agent", control_mode: "managed"},
               nil
             )
  end
end
