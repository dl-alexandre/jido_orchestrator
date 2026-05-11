defmodule JX.OrchestratorRecoveryTest do
  use ExUnit.Case, async: true

  alias JX.OrchestratorRecovery

  test "build names remote reattach local recovery duplicates and corrupt observations" do
    recovery =
      OrchestratorRecovery.build(%{
        totals: %{orphan_remote: 1, local_without_remote: 1, duplicate_paths: 1},
        orphan_remote: [
          %{
            local_ref: "",
            ssh_target: "builder@example.test",
            tmux_server: "default",
            session_name: "agent",
            current_path: "/repo"
          }
        ],
        local_without_remote: [
          %{
            ref: "s-local",
            state: "tracking",
            pane: "default/agent:0.0",
            path: "/repo",
            next_step: "observe before prompting"
          }
        ],
        duplicate_paths: [
          %{path: "/repo", refs: ["s-one", "s-two"], projects: ["saysure"]}
        ],
        errors: [:bad_snapshot]
      })

    assert recovery.status == "needs_recovery"
    assert recovery.counts.orphan_remote == 1
    assert recovery.recommendations_total == 4

    assert Enum.map(recovery.recommendations, & &1.action) == [
             "reattach-remote-session",
             "recover-local-session",
             "resolve-duplicate-session-path",
             "inspect-corrupt-observation"
           ]
  end
end
