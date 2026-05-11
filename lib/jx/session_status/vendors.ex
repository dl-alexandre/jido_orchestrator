defmodule JX.SessionStatus.Vendors do
  @moduledoc """
  Catalogue of external coding-agent UIs whose terminal output
  `JX.SessionStatus` interprets, and a fixture corpus pinning the
  classification for each.

  Vendor-coupled regex patterns live inline in `JX.SessionStatus`
  (grouped by vendor with comments) because their position in the cascade
  matters. This module is the **regression net** for silent UI drift:
  when an agent CLI ships a UI string change, the corresponding fixture
  test in `test/jx/session_status/vendors_test.exs` will start
  failing instead of work-state classification quietly degrading to
  `unknown`.

  ## Update procedure when a vendor releases a UI change

    1. Capture a representative scrollback fixture from the new release.
    2. Add it to `fixtures/0` under the right vendor.
    3. Run `mix test test/jx/session_status/vendors_test.exs`.
    4. If the fixture's expected work state still matches, you're done.
    5. Otherwise update the patterns in `JX.SessionStatus` and bump
       `:verified_version`.

  Each fixture is a `%{output:, expected_state:, note:}`. `expected_state`
  must be one of `JX.SessionStatus.work_states/0`.
  """

  @doc """
  Map of vendor name to last-verified version tag.

  Update the version when patterns or fixtures are refreshed against a
  newer release of the vendor's CLI. Use `unverified` if no specific
  version has been confirmed.
  """
  def verified_versions do
    %{
      "claude_code" => "2.1.x",
      "opencode" => "unverified",
      "codex" => "unverified"
    }
  end

  @doc """
  Fixture scrollback samples per vendor with their expected work state.

  These are real-shaped terminal tails captured from each agent CLI.
  They are exercised by the vendors test to guarantee that the existing
  patterns in `JX.SessionStatus` keep classifying canonical
  scrollback correctly across refactors.
  """
  def fixtures do
    %{
      "claude_code" => claude_code_fixtures(),
      "opencode" => opencode_fixtures(),
      "codex" => codex_fixtures()
    }
  end

  @doc "Flatten `fixtures/0` into a list of `{vendor, fixture}` pairs."
  def all_fixtures do
    fixtures()
    |> Enum.flat_map(fn {vendor, list} ->
      Enum.map(list, &{vendor, &1})
    end)
  end

  defp claude_code_fixtures do
    [
      %{
        note: "tempering spinner with token counter",
        expected_state: "running",
        output: "✳ Tempering... (1m 10s · ↑ 2.5k tokens)"
      },
      %{
        note: "active writing line above accept-edits footer with PR + interrupt hint",
        expected_state: "running",
        output: """
        ✢ Writing context tests… (2m 26s · ↓ 597 tokens)
        ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · esc to interrupt · ctrl+t to hide tasks
        """
      },
      %{
        note: "background shell still running footer",
        expected_state: "running",
        output: """
        Bash(MIX_ENV=test mix test --cover)
          ⎿  Running in the background (↓ to manage)

        ✻ Cogitated for 4m 12s · 1 shell still running
        ⏵⏵ accept edits on · 1 shell · ctrl+t to hide tasks · ↓ to manage
        """
      },
      %{
        note: "monitor still running footer",
        expected_state: "running",
        output: """
        Progress update — 8 pass / 3 pending / 0 fail.

        ✻ Cogitated for 1m 6s · 1 monitor still running
        ⏵⏵ accept edits on · 1 monitor · ctrl+t to hide tasks · ↓ to manage
        """
      },
      %{
        note: "permission menu (waiting on operator approval)",
        expected_state: "waiting",
        output: """
        Bash command

           grep -A3 'class="miss"' cover/Elixir.ExampleApp.FarmManagement.html

        Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don't ask again
           3. No

        Esc to cancel · Tab to amend · ctrl+e to explain
        """
      },
      %{
        note: "completed report with idle accept-edits footer",
        expected_state: "idle",
        output: """
        Status — Plantings tests added
        mix test test/one/farms/plantings_test.exs
        25 tests, 0 failures
        ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · esc to interrupt · ctrl+t to hide tasks
        """
      },
      %{
        note: "current monitor footer overrides older error in scrollback",
        expected_state: "running",
        output: """
        Error: exit code 3
        Test job failed before cleanup finished
        ⏵⏵ bypass permissions on · PR #461 · 1 monitor · ↓ to manage
        """
      }
    ]
  end

  defp opencode_fixtures do
    [
      %{
        note: "interrupt spinner with usage and commands hint",
        expected_state: "running",
        output: "⬝⬝⬝⬝⬝⬝⬝⬝ esc interrupt 71.7K (27%) · $1.36 ctrl+p commands"
      },
      %{
        note: "command UI footer (idle composer)",
        expected_state: "idle",
        output: "66.4K (25%) · $1.14 ctrl+p commands"
      },
      %{
        note: "current footer overrides older Thinking: line",
        expected_state: "idle",
        output: "Thinking: checking the repository\n50.5K (19%) · $0.93 ctrl+p commands"
      }
    ]
  end

  defp codex_fixtures do
    [
      %{
        note: "weekly usage footer (idle)",
        expected_state: "idle",
        output: "5h 94% · weekly 94%"
      },
      %{
        note: "current weekly footer overrides older command error",
        expected_state: "idle",
        output: "Error: seconds must be a positive integer\n5h 94% · weekly 94%"
      }
    ]
  end
end
