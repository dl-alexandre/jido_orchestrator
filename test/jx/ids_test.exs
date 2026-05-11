defmodule JX.IDsTest do
  use ExUnit.Case, async: true

  alias JX.IDs

  test "session names are deterministic and tmux safe" do
    hash = IDs.prompt_hash("Saysure", "Refactor webhook boundary")
    task_id = IDs.task_id(hash)

    assert task_id =~ ~r/^task-[a-f0-9]{12}$/
    assert IDs.branch(task_id) == "jx/#{task_id}"

    assert IDs.session_name("Saysure", task_id, "Claude") ==
             "jx_saysure_#{String.replace(task_id, "-", "_")}_claude"

    refute String.contains?(IDs.session_name("Saysure", task_id, "Claude"), ":")
    refute String.contains?(IDs.session_name("Saysure", task_id, "Claude"), "-")
  end
end
