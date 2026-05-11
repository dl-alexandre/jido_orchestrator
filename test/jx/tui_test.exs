defmodule JX.TUITest do
  use ExUnit.Case, async: true

  alias JX.TUI

  test "plan describes the monitorable TUI loop" do
    plan = TUI.plan()

    assert plan.name == "jx TUI runbook"
    assert Enum.any?(plan.monitor_loop, &(&1.command == "jx tui --no-observe"))
    assert Enum.any?(plan.primary_surfaces, &(&1.command == "jx tui"))
    assert Enum.any?(plan.primary_surfaces, &(&1.command == "jx tui snapshot"))
    assert Enum.any?(plan.success_criteria, &String.contains?(&1, "one command"))
  end

  test "snapshot builds a compact monitor packet" do
    assert {:ok, snapshot} = TUI.snapshot(observe: false, consumer: "tui-test")

    assert snapshot.headline
    assert snapshot.next.command
    assert snapshot.counts.sessions_total >= 0
    assert snapshot.health.status in ["ok", "attention"]
    assert snapshot.monitor.consumer == "tui-test"
    assert is_list(snapshot.agenda)
    assert Enum.any?(snapshot.commands, &(&1.label == "watch"))
  end
end
