defmodule JX.CiDigestTest do
  use ExUnit.Case, async: false

  alias JX.CiDigest
  alias JX.Jido.Actions.CiDigest, as: CiDigestAction

  test "classifies coverage threshold failure after a passing test suite" do
    log = """
    Finished in 535.1 seconds (361.8s async, 173.3s sync)
    198 doctests, 6544 tests, 0 failures, 12 skipped (390 excluded)

    Coverage test failed, threshold not met:

        Coverage:   41.13%
        Threshold:  90.00%

    ##[error]Process completed with exit code 3.
    """

    assert %{
             type: "coverage-threshold",
             summary: "tests passed; coverage 41.13% is below threshold 90.00%",
             evidence: evidence
           } = CiDigest.classify_log(log)

    assert evidence =~ "198 doctests, 6544 tests, 0 failures"
    assert evidence =~ "Coverage:   41.13%"
  end

  test "keeps DB ownership errors as warnings when coverage is the final failure" do
    log = """
    ** (DBConnection.OwnershipError) cannot find ownership process
    Finished in 395.2 seconds
    198 doctests, 6529 tests, 0 failures, 12 skipped (390 excluded)
    Coverage test failed, threshold not met:
        Coverage:   41.27%
        Threshold:  90.00%
    """

    assert %{type: "coverage-threshold", warnings: [warning]} = CiDigest.classify_log(log)
    assert warning =~ "DBConnection ownership"
  end

  test "classifies logs with failing tests" do
    log = """
    1) test renders thing (ExampleWeb.SomeTest)
    Assertion with == failed
    Finished in 10.0 seconds
    0 doctests, 20 tests, 1 failure
    """

    assert %{type: "test-failure", summary: "1 test failure(s)"} = CiDigest.classify_log(log)
  end

  test "classifies Credo failures with issue evidence" do
    log = """
    2026-04-26T20:30:52.7623910Z [D] Duplicate code found in lib/one/farms.ex:882 (mass: 50).
    2026-04-26T20:30:52.7683708Z [F] Pass an `:async` boolean option to `use` a test case module.
    2026-04-26T20:30:52.9770541Z 14725 mods/funs, found 1 consistency issue, 3 warnings, 18 refactoring opportunities, 2 code readability issues, 8 software design suggestions.
    ##[error]Process completed with exit code 17.
    """

    assert %{
             type: "credo",
             summary:
               "Credo failed: found 1 consistency issue, 3 warnings, 18 refactoring opportunities, 2 code readability issues, 8 software design suggestions.",
             evidence: evidence
           } = CiDigest.classify_log(log)

    assert evidence =~ "Duplicate code found in lib/one/farms.ex:882"
    assert evidence =~ "Pass an `:async` boolean option"
  end

  test "build groups check totals and blockers" do
    checks = [
      %{
        name: "Test",
        bucket: "fail",
        workflow: "CI",
        link: "https://github.com/o/r/actions/runs/1/job/2"
      },
      %{name: "Format", bucket: "pass", workflow: "CI"},
      %{name: "Credo", bucket: "pending", workflow: "CI"}
    ]

    digest =
      CiDigest.build("o/r", 12, checks, %{
        "Test" => %{
          type: "coverage-threshold",
          summary: "tests passed",
          evidence: "coverage",
          warnings: []
        }
      })

    assert digest.overall == "fail"
    assert digest.totals["fail"] == 1
    assert digest.totals["pass"] == 1
    assert digest.totals["pending"] == 1
    assert [%{check: "Test", type: "coverage-threshold"}] = digest.blockers
  end

  test "extracts job id from GitHub Actions job link" do
    assert CiDigest.job_id_from_link("https://github.com/o/r/actions/runs/123/job/456") == "456"
    assert CiDigest.job_id_from_link("https://github.com/o/r/actions/runs/123") == nil
  end

  test "run fetches checks metadata and failed job logs through gh" do
    with_fake_gh("""
    #!/bin/sh
    if [ "$1 $2" = "pr checks" ]; then
      printf '%s\n' '[
        {"name":"Test","state":"FAILURE","workflow":"CI","link":"https://github.com/o/r/actions/runs/123/job/456"},
        {"name":"Format","state":"SUCCESS","workflow":"CI","link":"https://github.com/o/r/actions/runs/123/job/457"},
        {"name":"Deploy","state":"CANCELLED","workflow":"Deploy","link":"https://github.com/o/r/actions/runs/123/job/458"},
        {"name":"Docs","state":"SKIPPED","workflow":"Docs","link":"https://github.com/o/r/actions/runs/123/job/459"}
      ]'
      exit 0
    fi

    if [ "$1 $2" = "pr view" ]; then
      printf '%s\n' '{"headRefOid":"abc123","headRefName":"feature","baseRefName":"main","url":"https://github.com/o/r/pull/14","updatedAt":"2026-05-10T00:00:00Z"}'
      exit 0
    fi

    if [ "$1" = "api" ]; then
      cat <<'LOG'
    Finished in 10.0 seconds
    0 doctests, 20 tests, 0 failures
    Coverage test failed, threshold not met:
        Coverage:   88.00%
        Threshold:  90.00%
    LOG
      exit 0
    fi

    printf 'unexpected gh args: %s\n' "$*" >&2
    exit 2
    """)

    assert {:ok, digest} = CiDigest.run("o/r", 14)

    assert digest.overall == "fail"
    assert digest.head_sha == "abc123"
    assert digest.head_ref_name == "feature"
    assert digest.base_ref_name == "main"
    assert digest.totals["fail"] == 1
    assert digest.totals["pass"] == 1
    assert digest.totals["cancel"] == 1
    assert digest.totals["skipping"] == 1
    assert [%{check: "Test", type: "coverage-threshold"}] = digest.blockers
  end

  test "run surfaces gh parse and command failures" do
    with_fake_gh("""
    #!/bin/sh
    if [ "$GH_MODE" = "bad_json" ]; then
      printf 'not-json'
      exit 0
    fi

    printf 'boom'
    exit 2
    """)

    System.put_env("GH_MODE", "bad_json")
    assert {:error, "failed to parse gh checks JSON" <> _} = CiDigest.run("o/r", 14)

    System.delete_env("GH_MODE")
    assert {:error, "gh pr checks exited 2: boom"} = CiDigest.run("o/r", 14)
  end

  test "run returns an error when gh is unavailable instead of raising" do
    path = System.get_env("PATH")
    System.put_env("PATH", "")

    try do
      assert {:error, "gh CLI not found"} = CiDigest.run("org/repo", 14, logs: false)
    after
      if path, do: System.put_env("PATH", path), else: System.delete_env("PATH")
    end
  end

  test "Jido action wraps the workspace CI digest result" do
    with_fake_gh("""
    #!/bin/sh
    if [ "$1 $2" = "pr checks" ]; then
      printf '%s\n' '[
        {"name":"Test","state":"SUCCESS","workflow":"CI","link":"https://github.com/o/r/actions/runs/123/job/456"}
      ]'
      exit 0
    fi

    printf 'unexpected gh args: %s\n' "$*" >&2
    exit 2
    """)

    assert {:ok, %{ci_digest: digest}} =
             CiDigestAction.run(%{repo: "o/r", pr: 14, opts: [logs: false, head: false]}, %{})

    assert digest.overall == "pass"
    assert digest.totals["pass"] == 1
    assert digest.checks |> List.first() |> Map.fetch!(:name) == "Test"
  end

  defp with_fake_gh(script) do
    tmp = Path.join(System.tmp_dir!(), "jx-fake-gh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    gh_path = Path.join(tmp, "gh")
    File.write!(gh_path, script)
    File.chmod!(gh_path, 0o755)

    old_path = System.get_env("PATH")
    System.put_env("PATH", tmp <> ":" <> (old_path || ""))

    on_exit(fn ->
      if old_path, do: System.put_env("PATH", old_path), else: System.delete_env("PATH")
      System.delete_env("GH_MODE")
      File.rm_rf(tmp)
    end)
  end
end
