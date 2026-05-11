defmodule JX.Workspace.PromotionTest do
  use ExUnit.Case, async: true

  alias JX.Workspace.Promotion

  test "blocked preflight prevents mutation" do
    caller = self()

    preflight_fun = fn _project, _source, _target ->
      {:ok, preflight(eligible: false, reasons: ["host:push_not_verified"])}
    end

    promotion_fun = fn _preflight ->
      send(caller, :promotion_called)
      {:ok, ["push master"]}
    end

    assert {:ok, report} =
             Promotion.run("example-project", "develop", "master", preflight_fun, promotion_fun)

    assert report.status == "blocked"
    assert report.actions == []
    assert report.errors == []
    refute_received :promotion_called
  end

  test "allowed preflight emits conservative promotion actions" do
    preflight_fun = fn _project, _source, _target -> {:ok, preflight(eligible: true)} end

    promotion_fun = fn _preflight ->
      {:ok,
       [
         "fetch develop master",
         "checkout master",
         "merge --ff-only refs/remotes/origin/develop",
         "push master"
       ]}
    end

    assert {:ok, report} =
             Promotion.run("example-project", "develop", "master", preflight_fun, promotion_fun)

    assert report.status == "promoted"

    assert report.actions == [
             "fetch develop master",
             "checkout master",
             "merge --ff-only refs/remotes/origin/develop",
             "push master"
           ]

    assert report.errors == []
  end

  test "ambiguous multi-host preflight prevents mutation" do
    caller = self()

    preflight_fun = fn _project, _source, _target ->
      {:ok,
       preflight(
         eligible: true,
         hosts: [%{host: "build-a"}, %{host: "build-b"}]
       )}
    end

    promotion_fun = fn _preflight ->
      send(caller, :promotion_called)
      {:ok, ["push master"]}
    end

    assert {:ok, report} =
             Promotion.run("example-project", "develop", "master", preflight_fun, promotion_fun)

    assert report.status == "failed"
    assert report.actions == []
    assert report.errors == ["ambiguous promotion hosts: build-a, build-b"]
    refute_received :promotion_called
  end

  test "merge failure returns failed" do
    preflight_fun = fn _project, _source, _target -> {:ok, preflight(eligible: true)} end

    promotion_fun = fn _preflight ->
      {:error,
       ["fetch develop master", "checkout master", "merge --ff-only refs/remotes/origin/develop"],
       ["merge failed: not possible to fast-forward"]}
    end

    assert {:ok, report} =
             Promotion.run("example-project", "develop", "master", preflight_fun, promotion_fun)

    assert report.status == "failed"
    assert report.errors == ["merge failed: not possible to fast-forward"]
  end

  test "push failure returns failed" do
    preflight_fun = fn _project, _source, _target -> {:ok, preflight(eligible: true)} end

    promotion_fun = fn _preflight ->
      {:error,
       [
         "fetch develop master",
         "checkout master",
         "merge --ff-only refs/remotes/origin/develop",
         "push master"
       ], ["push failed: denied"]}
    end

    assert {:ok, report} =
             Promotion.run("example-project", "develop", "master", preflight_fun, promotion_fun)

    assert report.status == "failed"
    assert report.errors == ["push failed: denied"]
  end

  test "promotion script uses only fetch checkout ff-only merge and push" do
    script = Promotion.promotion_script("/srv/repos/one", "develop", "master")

    assert script =~
             ~s(git fetch "$remote" "refs/heads/$source:$source_ref" "refs/heads/$target:$target_ref")

    assert script =~ ~s(git checkout "$target")
    assert script =~ ~s(git merge --ff-only "$source_ref")
    assert script =~ ~s(git push "$remote" "$target")

    refute script =~ "git push --force"
    refute script =~ "git push -f"
    refute script =~ "git reset --hard"
    refute script =~ "git branch -d"
    refute script =~ "git branch -D"
    refute script =~ "git worktree remove"
  end

  test "promotion output parser returns failed for merge and push errors" do
    assert Promotion.parse_output("""
           jx-promotion-run\t1
           action\tfetch develop master
           action\tcheckout master
           action\tmerge --ff-only refs/remotes/origin/develop
           status\tfailed
           error\tmerge failed: no fast-forward
           """) ==
             {:error,
              [
                "fetch develop master",
                "checkout master",
                "merge --ff-only refs/remotes/origin/develop"
              ], ["merge failed: no fast-forward"]}

    assert Promotion.parse_output("""
           jx-promotion-run\t1
           action\tfetch develop master
           action\tcheckout master
           action\tmerge --ff-only refs/remotes/origin/develop
           action\tpush master
           status\tfailed
           error\tpush failed: denied
           """) ==
             {:error,
              [
                "fetch develop master",
                "checkout master",
                "merge --ff-only refs/remotes/origin/develop",
                "push master"
              ], ["push failed: denied"]}
  end

  defp preflight(opts) do
    eligible = Keyword.fetch!(opts, :eligible)

    %{
      project: "example-project",
      source_branch: "develop",
      target_branch: "master",
      eligible: eligible,
      status: if(eligible, do: "allowed", else: "blocked"),
      project_gate: %{hosts: Keyword.get(opts, :hosts, [%{host: "build-1"}])},
      reasons: Keyword.get(opts, :reasons, []),
      required_fixes: Keyword.get(opts, :required_fixes, [])
    }
  end
end
