defmodule JX.Workspace.ProjectGateTest do
  use ExUnit.Case, async: true

  alias JX.Workspace.ProjectGate

  test "all hosts eligible allows project promotion" do
    gate =
      ProjectGate.evaluate("example-project", %{
        instances: [
          host_result("build-a", eligible: true),
          host_result("build-b", eligible: true)
        ]
      })

    assert gate == %{
             project: "example-project",
             eligible: true,
             status: "allowed",
             hosts: [
               host_result("build-a", eligible: true),
               host_result("build-b", eligible: true)
             ],
             reasons: [],
             required_fixes: []
           }
  end

  test "one blocked host blocks the project" do
    gate =
      ProjectGate.evaluate("example-project", %{
        instances: [
          host_result("build-a", eligible: true),
          host_result("uitestserver",
            eligible: false,
            reasons: ["push_not_verified"],
            required_fixes: ["Restore GitHub auth and rerun repo doctor."]
          )
        ]
      })

    refute gate.eligible
    assert gate.status == "blocked"
    assert gate.reasons == ["uitestserver:push_not_verified"]

    assert gate.required_fixes == [
             "uitestserver: Restore GitHub auth and rerun repo doctor."
           ]
  end

  test "no hosts blocks the project" do
    assert ProjectGate.evaluate("missing", %{instances: []}) == %{
             project: "missing",
             eligible: false,
             status: "blocked",
             hosts: [],
             reasons: ["no_hosts_registered"],
             required_fixes: ["Register at least one host/repo for the project."]
           }
  end

  test "reason and fix aggregation is deterministic" do
    gate =
      ProjectGate.evaluate("example-project", %{
        instances: [
          host_result("z-host",
            eligible: false,
            reasons: ["push_not_verified"],
            required_fixes: ["Restore GitHub auth and rerun repo doctor."]
          ),
          host_result("a-host",
            eligible: false,
            reasons: ["dirty_drift", "fetch_failed"],
            required_fixes: [
              "Reconcile repository drift and rerun repo doctor.",
              "Restore GitHub auth and rerun repo doctor."
            ]
          )
        ]
      })

    assert Enum.map(gate.hosts, & &1.host) == ["a-host", "z-host"]

    assert gate.reasons == [
             "a-host:dirty_drift",
             "a-host:fetch_failed",
             "z-host:push_not_verified"
           ]

    assert gate.required_fixes == [
             "a-host: Reconcile repository drift and rerun repo doctor.",
             "a-host: Restore GitHub auth and rerun repo doctor.",
             "z-host: Restore GitHub auth and rerun repo doctor."
           ]
  end

  defp host_result(host, opts) do
    eligible = Keyword.fetch!(opts, :eligible)

    %{
      host: host,
      repo_path: "/srv/repos/#{host}",
      eligible: eligible,
      status: if(eligible, do: "allowed", else: "blocked"),
      reasons: Keyword.get(opts, :reasons, []),
      required_fixes: Keyword.get(opts, :required_fixes, []),
      reconciliation_status: "reconciled",
      trust_status: "trusted",
      confidence: "high",
      drift_status: "none",
      auth: %{
        fetch_allowed: "ok",
        push_allowed: "ok",
        api_allowed: "unknown"
      }
    }
  end
end
