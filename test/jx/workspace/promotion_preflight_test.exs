defmodule JX.Workspace.PromotionPreflightTest do
  use ExUnit.Case, async: true

  alias JX.Workspace.PromotionPreflight

  test "allowed project gate allows preflight" do
    project_gate = project_gate(eligible: true)

    assert PromotionPreflight.evaluate("example-project", "develop", "master", project_gate) == %{
             project: "example-project",
             source_branch: "develop",
             target_branch: "master",
             eligible: true,
             status: "allowed",
             project_gate: project_gate,
             reasons: [],
             required_fixes: []
           }
  end

  test "blocked project gate blocks preflight" do
    project_gate =
      project_gate(
        eligible: false,
        reasons: ["uitestserver:push_not_verified"],
        required_fixes: ["uitestserver: Restore GitHub auth and rerun repo doctor."]
      )

    preflight = PromotionPreflight.evaluate("example-project", "develop", "master", project_gate)

    refute preflight.eligible
    assert preflight.status == "blocked"
    assert preflight.reasons == ["uitestserver:push_not_verified"]

    assert preflight.required_fixes == [
             "uitestserver: Restore GitHub auth and rerun repo doctor."
           ]
  end

  test "run delegates to project gate with source and target branches" do
    caller = self()

    project_gate_fun = fn project, opts ->
      send(caller, {:project_gate, project, opts})
      {:ok, project_gate(eligible: true)}
    end

    assert {:ok, %{eligible: true}} =
             PromotionPreflight.run(
               "example-project",
               "develop",
               "master",
               project_gate_fun
             )

    assert_received {:project_gate, "example-project",
                     [base_branch: "develop", promote_branch: "master"]}
  end

  defp project_gate(opts) do
    eligible = Keyword.fetch!(opts, :eligible)

    %{
      project: "example-project",
      eligible: eligible,
      status: if(eligible, do: "allowed", else: "blocked"),
      hosts: [],
      reasons: Keyword.get(opts, :reasons, []),
      required_fixes: Keyword.get(opts, :required_fixes, [])
    }
  end
end
