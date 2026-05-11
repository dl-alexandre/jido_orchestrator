defmodule JX.TmuxTest do
  use ExUnit.Case, async: true

  alias JX.Tmux

  test "default server commands are explicit so nested tmux sessions do not shadow them" do
    assert Tmux.command("default") == "tmux -L default"
    assert Tmux.args(["list-sessions"], "default") == ["-L", "default", "list-sessions"]
  end

  test "all-server discovery probes the explicit default socket" do
    assert Tmux.list_all_sessions_script() =~ "emit_sessions default tmux -L default"
    assert Tmux.list_all_panes_script() =~ "emit_panes default tmux -L default"
  end
end
