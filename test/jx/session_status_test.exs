defmodule JX.SessionStatusTest do
  use ExUnit.Case, async: true

  alias JX.SessionStatus

  test "analyze marks skipped captures as unobservable" do
    assert SessionStatus.analyze(%{}, %{status: "skipped", output: ""}) == %{
             work_state: "unobservable",
             signals: ["no_tmux_pane"]
           }
  end

  test "analyze marks rejected pushes as blocked" do
    output = """
    Error: Exit code 1
    ! [rejected] feat/example -> feat/example (fetch first)
    error: failed to push some refs
    """

    status = SessionStatus.analyze(%{}, %{status: "ok", output: output})

    assert status.work_state == "blocked"
    assert "blocked" in status.signals
  end

  test "analyze marks active agent text as running" do
    output = "✳ Tempering... (1m 10s · ↑ 2.5k tokens)"

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "running",
             signals: ["running"]
           }
  end

  test "analyze marks opencode interrupt spinner as running" do
    output = "⬝⬝⬝⬝⬝⬝⬝⬝ esc interrupt 71.7K (27%) · $1.36 ctrl+p commands"

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "running",
             signals: ["running"]
           }
  end

  test "analyze marks active claude work above an idle-looking footer as running" do
    output = """
    ✢ Writing context tests… (2m 26s · ↓ 597 tokens)
    ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · esc to interrupt · ctrl+t to hide tasks
    """

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "running",
             signals: ["running"]
           }
  end

  test "analyze marks thinking tool transcript above a footer as running" do
    output = """
    ⏺ Thinking
      ⎿  Working through it…

    ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · esc to interrupt · ctrl+t to hide tasks
    """

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "running",
             signals: ["running"]
           }
  end

  test "analyze marks claude background shells as running" do
    output = """
    Bash(MIX_ENV=test mix test --cover)
      ⎿  Running in the background (↓ to manage)

    ✻ Cogitated for 4m 12s · 1 shell still running
    ⏵⏵ accept edits on · 1 shell · ctrl+t to hide tasks · ↓ to manage
    """

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "running",
             signals: ["running"]
           }
  end

  test "analyze marks claude background monitors as running" do
    output = """
    Progress update — 8 pass / 3 pending / 0 fail.

    ✻ Cogitated for 1m 6s · 1 monitor still running
    ⏵⏵ accept edits on · 1 monitor · ctrl+t to hide tasks · ↓ to manage
    """

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "running",
             signals: ["running"]
           }
  end

  test "active_work? recognizes claude monitor footer" do
    assert SessionStatus.active_work?("⏵⏵ accept edits on · 1 monitor · ctrl+t to hide tasks")
  end

  test "interrupt_hint? ignores an idle agent footer with an interrupt hint" do
    refute SessionStatus.interrupt_hint?(
             "⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · esc to interrupt"
           )
  end

  test "interrupt_hint? recognizes a standalone interruptible progress footer" do
    assert SessionStatus.interrupt_hint?(
             "⬝⬝⬝⬝⬝⬝⬝⬝ esc interrupt 71.7K (27%) · $1.36 ctrl+p commands"
           )
  end

  test "analyze marks waiting prompts as waiting" do
    output = "Would you like me to create a proper issue for it?"

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "waiting",
             signals: ["waiting"]
           }
  end

  test "analyze marks claude permission menus as waiting" do
    output = """
    Bash command

       grep -A3 'class="miss"' cover/Elixir.ExampleApp.FarmManagement.html

    Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and don't ask again
       3. No

    Esc to cancel · Tab to amend · ctrl+e to explain
    """

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "waiting",
             signals: ["waiting"]
           }
  end

  test "approval_prompt? recognizes command approval menus" do
    output = """
    Bash command

       git commit -m "test: fix scoped files"

    This command requires approval

    Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and don't ask again
       3. No

    Esc to cancel · Tab to amend · ctrl+e to explain
    """

    assert SessionStatus.approval_prompt?(output)
  end

  test "staged_prompt? recognizes pasted text waiting at the composer" do
    output = """
    ──────────────────────────────────────────────────────────────
    ❯ [Pasted text #1]Enter
    ──────────────────────────────────────────────────────────────
      ⏵⏵ accept edits on (shift+tab to cycle)
    """

    assert SessionStatus.staged_prompt?(output)
    refute SessionStatus.final_response?(output)
    refute SessionStatus.meaningful_response?(output)
  end

  test "analyze marks command UI footer as idle" do
    output = "66.4K (25%) · $1.14 ctrl+p commands"

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "idle",
             signals: ["idle"]
           }
  end

  test "analyze marks shell prompts as idle" do
    output = "…/workspaces/go ❯"

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "idle",
             signals: ["idle"]
           }
  end

  test "analyze marks prompt composer help as idle" do
    output = "Esc to cancel · Tab to amend · ctrl+e to explain"

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "idle",
             signals: ["idle"]
           }
  end

  test "analyze marks accept edits agent footer as idle" do
    output = "⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · ctrl+t to hide tasks"

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "idle",
             signals: ["idle"]
           }
  end

  test "analyze marks completed claude footer with interrupt hint as idle" do
    output = """
    Status — Plantings tests added
    mix test test/one/farms/plantings_test.exs
    25 tests, 0 failures
    ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · esc to interrupt · ctrl+t to hide tasks
    """

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "idle",
             signals: ["idle"]
           }
  end

  test "analyze does not treat plain running words in transcript as active work" do
    output = "Update Formulas runs successfully\n66.4K (25%) · $1.14 ctrl+p commands"

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "idle",
             signals: ["idle"]
           }
  end

  test "analyze ignores stale running text outside the recent tail" do
    output =
      ["Thinking: checking the repository"]
      |> Kernel.++(Enum.map(1..25, &"old transcript line #{&1}"))
      |> Kernel.++(["66.4K (25%) · $1.14 ctrl+p commands"])
      |> Enum.join("\n")

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "idle",
             signals: ["idle"]
           }
  end

  test "analyze lets a current opencode footer beat older recent running text" do
    output = "Thinking: checking the repository\n50.5K (19%) · $0.93 ctrl+p commands"

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "idle",
             signals: ["idle"]
           }
  end

  test "analyze lets a current codex footer beat older recent command errors" do
    output = "Error: seconds must be a positive integer\n5h 94% · weekly 94%"

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "idle",
             signals: ["idle"]
           }
  end

  test "analyze marks a current claude monitor footer as running despite older command errors" do
    output = """
    Error: exit code 3
    Test job failed before cleanup finished
    ⏵⏵ bypass permissions on · PR #461 · 1 monitor · ↓ to manage
    """

    assert SessionStatus.analyze(%{}, %{status: "ok", output: output}) == %{
             work_state: "running",
             signals: ["running"]
           }
  end

  test "meaningful_response? rejects agent UI chrome" do
    refute SessionStatus.meaningful_response?(
             "⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · ctrl+t to hide tasks"
           )

    refute SessionStatus.meaningful_response?("Esc to cancel · Tab to amend · ctrl+e to explain")
    refute SessionStatus.meaningful_response?("Claude Code v2.1.108\n❯\n⏵⏵ bypass permissions on")
  end

  test "meaningful_response? accepts agent answer content around chrome" do
    output = """
    No code changes, pushes, merges, or rebases performed.
    ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · ctrl+t to hide tasks
    """

    assert SessionStatus.meaningful_response?(output)
  end

  test "meaningful_response_after? ignores old content before the latest directive" do
    output = """
    Previous answer with useful details.

    ❯ Report current status, blockers, changed files, and the next concrete step.

    ───────────────────────────────────────────────────────────────────────────
      ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · ctrl+t to hide tasks
    """

    refute SessionStatus.meaningful_response_after?(
             output,
             "Report current status, blockers, changed files, and the next concrete step."
           )
  end

  test "meaningful_response_after? accepts content after the latest directive" do
    output = """
    Previous answer with useful details.

    ❯ Report current status, blockers, changed files, and the next concrete step.

    Current Status
    No code changes, pushes, merges, or rebases performed.
    ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · ctrl+t to hide tasks
    """

    assert SessionStatus.meaningful_response_after?(
             output,
             "Report current status, blockers, changed files, and the next concrete step."
           )
  end

  test "meaningful_response_after? refuses old content when directive marker is missing" do
    output = """
    Previous answer with useful details.

    Esc to cancel · Tab to amend · ctrl+e to explain
    """

    refute SessionStatus.meaningful_response_after?(
             output,
             "Report current status, blockers, changed files, and the next concrete step."
           )
  end

  test "meaningful_response_after? tolerates directive line wrapping" do
    output = """
    ❯ Report current status, blockers, changed files,
    and the next concrete step.

    Current Status
    Targeted tests are passing.
    """

    assert SessionStatus.meaningful_response_after?(
             output,
             "Report current status, blockers, changed files, and the next concrete step."
           )
  end

  test "meaningful_response_after? preserves wrapped response lines when matching a wrapped directive" do
    marker =
      "Proceed with the Plantings nil-guard fix next. Run mix format on touched files, run mix test test/one/farms/plantings_test.exs, and report changed files, test results, blockers, and the next highest-value target. Do not push."

    output = """
    ❯ Proceed with the Plantings nil-guard fix next. Run mix format on touched files, run mix test
      test/one/farms/plantings_test.exs, and report changed files, test results, blockers, and the next highest-value target. Do not push.

    Status — Plantings nil-guard fix applied
    mix test test/one/farms/plantings_test.exs
    25 tests, 0 failures
    ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · esc to interrupt · ctrl+t to hide tasks
    """

    assert SessionStatus.meaningful_response_after?(output, marker)
  end

  test "final_response_after? rejects tool transcript without authored response" do
    marker = "Monitor PR #460 CI for commit 2bc15e02."

    output = """
    ❯ #{marker}

    ⏺ Bash(gh pr checks 460 --repo acme-corp/example-project)
      ⎿  Check Coverage on Changed Files    pending 0
         Compile & Verify                   pending 0

    ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · ctrl+t to hide tasks
    """

    refute SessionStatus.final_response_after?(output, marker)
  end

  test "final_response_after? accepts authored response after tool transcript" do
    marker = "Monitor PR #460 CI for commit 2bc15e02."

    output = """
    ❯ #{marker}

    ⏺ Bash(gh pr checks 460 --repo acme-corp/example-project)
      ⎿  Check Coverage on Changed Files    pass 1m

    CI status
    All checks for 2bc15e02 are passing.
    ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · ctrl+t to hide tasks
    """

    assert SessionStatus.final_response_after?(output, marker)
  end

  test "summary returns the last nonblank compact line" do
    assert SessionStatus.summary("first\n\n  second   line  \n", 100) == "second line"
  end
end
