defmodule JX.CiDigest do
  @moduledoc """
  Small GitHub Actions check digest for operator decisions.

  The digest intentionally stays read-only. It uses the `gh` CLI when fetching
  live data, while keeping log classification pure and testable.
  """

  @buckets ~w(pass fail pending skipping cancel)

  def run(repo, pr_number, opts \\ []) do
    with {:ok, checks} <- fetch_checks(repo, pr_number) do
      metadata = fetch_metadata(repo, pr_number, opts)

      classifications =
        if Keyword.get(opts, :logs, true) do
          classify_failed_logs(repo, checks)
        else
          %{}
        end

      {:ok, build(repo, pr_number, checks, classifications, metadata)}
    end
  end

  def build(repo, pr_number, checks, classifications \\ %{}, metadata \\ %{}) do
    checks = Enum.map(checks, &normalize_check/1)

    checks =
      Enum.map(checks, fn check ->
        Map.put(check, :classification, Map.get(classifications, check.name))
      end)

    %{
      repo: repo,
      pr: pr_number,
      overall: overall(checks),
      totals: totals(checks),
      blockers: blockers(checks),
      head_sha: metadata_field(metadata, :headRefOid),
      head_ref_name: metadata_field(metadata, :headRefName),
      base_ref_name: metadata_field(metadata, :baseRefName),
      url: metadata_field(metadata, :url),
      updated_at: metadata_field(metadata, :updatedAt),
      metadata_error: metadata_field(metadata, :metadata_error),
      checks: checks
    }
  end

  def classify_log(log) do
    log = to_string(log)
    coverage = coverage_failure(log)
    tests = test_summary(log)
    credo = credo_failure(log)
    db_ownership? = String.contains?(log, "DBConnection.OwnershipError")

    cond do
      coverage && zero_failures?(tests) ->
        %{
          type: "coverage-threshold",
          summary:
            "tests passed; coverage #{coverage.coverage}% is below threshold #{coverage.threshold}%",
          evidence: evidence([test_evidence(tests), coverage.evidence]),
          warnings: warnings(db_ownership?)
        }

      coverage ->
        %{
          type: "coverage-threshold",
          summary: "coverage #{coverage.coverage}% is below threshold #{coverage.threshold}%",
          evidence: evidence([test_evidence(tests), coverage.evidence]),
          warnings: warnings(db_ownership?)
        }

      credo ->
        %{
          type: "credo",
          summary: credo.summary,
          evidence: credo.evidence,
          warnings: warnings(db_ownership?)
        }

      failure_count(tests) > 0 ->
        %{
          type: "test-failure",
          summary: "#{failure_count(tests)} test failure(s)",
          evidence: evidence([test_evidence(tests), first_failure(log)]),
          warnings: warnings(db_ownership?)
        }

      db_ownership? ->
        %{
          type: "db-ownership",
          summary: "DBConnection ownership errors found in failed job log",
          evidence: first_failure(log),
          warnings: []
        }

      true ->
        %{
          type: "unknown-failure",
          summary: "failed check; no known failure pattern matched",
          evidence: first_failure(log),
          warnings: []
        }
    end
  end

  def job_id_from_link(link) when is_binary(link) do
    case Regex.run(~r{/actions/runs/\d+/job/(\d+)}, link) do
      [_, job_id] -> job_id
      _ -> nil
    end
  end

  def job_id_from_link(_link), do: nil

  defp fetch_checks(repo, pr_number) do
    args = [
      "pr",
      "checks",
      to_string(pr_number),
      "--repo",
      repo,
      "--json",
      "name,state,bucket,workflow,link,description,startedAt,completedAt"
    ]

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, status} when status in [0, 8] ->
        case Jason.decode(output) do
          {:ok, checks} ->
            {:ok, checks}

          {:error, error} ->
            {:error, "failed to parse gh checks JSON: #{Exception.message(error)}"}
        end

      {output, status} ->
        {:error, "gh pr checks exited #{status}: #{String.trim(output)}"}
    end
  rescue
    error in ErlangError ->
      if Exception.message(error) == "Erlang error: :enoent" do
        {:error, "gh CLI not found"}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp fetch_metadata(repo, pr_number, opts) do
    if Keyword.get(opts, :head, true) do
      fetch_pr_metadata(repo, pr_number)
    else
      %{}
    end
  end

  defp fetch_pr_metadata(repo, pr_number) do
    args = [
      "pr",
      "view",
      to_string(pr_number),
      "--repo",
      repo,
      "--json",
      "headRefOid,headRefName,baseRefName,url,updatedAt"
    ]

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, metadata} -> metadata
          {:error, error} -> %{metadata_error: Exception.message(error)}
        end

      {output, status} ->
        %{metadata_error: "gh pr view exited #{status}: #{String.trim(output)}"}
    end
  rescue
    error in ErlangError ->
      if Exception.message(error) == "Erlang error: :enoent" do
        %{metadata_error: "gh CLI not found"}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp classify_failed_logs(repo, checks) do
    checks
    |> Enum.map(&normalize_check/1)
    |> Enum.filter(&(&1.bucket == "fail"))
    |> Map.new(fn check ->
      classification =
        case job_id_from_link(check.link) do
          nil ->
            %{
              type: "unknown-failure",
              summary: "failed check has no job log link",
              evidence: check.link,
              warnings: []
            }

          job_id ->
            repo
            |> fetch_job_log(job_id)
            |> case do
              {:ok, log} ->
                classify_log(log)

              {:error, reason} ->
                %{
                  type: "unknown-failure",
                  summary: "could not fetch job log",
                  evidence: reason,
                  warnings: []
                }
            end
        end

      {check.name, classification}
    end)
  end

  defp fetch_job_log(repo, job_id) do
    path = "repos/#{api_repo(repo)}/actions/jobs/#{job_id}/logs"

    case System.cmd("gh", ["api", path], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, "gh api exited #{status}: #{String.trim(output)}"}
    end
  end

  defp api_repo(repo) do
    repo
    |> String.trim()
    |> String.replace_prefix("https://github.com/", "")
    |> String.replace_prefix("github.com/", "")
    |> String.trim("/")
  end

  defp normalize_check(check) do
    %{
      name: field(check, :name),
      state: field(check, :state),
      bucket: field(check, :bucket) || bucket_for_state(field(check, :state)),
      workflow: field(check, :workflow),
      link: field(check, :link),
      description: field(check, :description),
      started_at: field(check, :startedAt),
      completed_at: field(check, :completedAt)
    }
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil

  defp metadata_field(map, key) do
    case field(map, key) do
      value when is_binary(value) -> value
      _value -> ""
    end
  end

  defp bucket_for_state(state) do
    case to_string(state) do
      "SUCCESS" -> "pass"
      "FAILURE" -> "fail"
      "ERROR" -> "fail"
      "CANCELLED" -> "cancel"
      "SKIPPED" -> "skipping"
      _ -> "pending"
    end
  end

  defp totals(checks) do
    frequencies = Enum.frequencies_by(checks, & &1.bucket)
    Map.new(@buckets, &{&1, Map.get(frequencies, &1, 0)}) |> Map.put("total", length(checks))
  end

  defp overall(checks) do
    cond do
      Enum.any?(checks, &(&1.bucket == "fail")) -> "fail"
      Enum.any?(checks, &(&1.bucket == "pending")) -> "pending"
      Enum.any?(checks, &(&1.bucket == "cancel")) -> "cancel"
      true -> "pass"
    end
  end

  defp blockers(checks) do
    checks
    |> Enum.filter(&(&1.bucket == "fail"))
    |> Enum.map(fn check ->
      classification =
        check.classification ||
          %{type: "unknown-failure", summary: "failed check", evidence: check.link, warnings: []}

      %{
        check: check.name,
        workflow: check.workflow,
        link: check.link,
        type: classification.type,
        summary: classification.summary,
        evidence: classification.evidence,
        warnings: classification.warnings
      }
    end)
  end

  defp coverage_failure(log) do
    case Regex.run(
           ~r/Coverage test failed, threshold not met:.*?Coverage:\s+([\d.]+)%.*?Threshold:\s+([\d.]+)%/s,
           log
         ) do
      [match, coverage, threshold] ->
        %{coverage: coverage, threshold: threshold, evidence: compact(match)}

      _ ->
        nil
    end
  end

  defp test_summary(log) do
    case Regex.scan(~r/(\d+)\s+doctests,\s+(\d+)\s+tests,\s+(\d+)\s+failures?/i, log) do
      [] ->
        nil

      matches ->
        [_, doctests, tests, failures] = List.last(matches)
        %{doctests: doctests, tests: tests, failures: String.to_integer(failures)}
    end
  end

  defp zero_failures?(%{failures: 0}), do: true
  defp zero_failures?(_tests), do: false

  defp failure_count(%{failures: failures}), do: failures
  defp failure_count(_tests), do: 0

  defp test_evidence(nil), do: nil

  defp test_evidence(%{doctests: doctests, tests: tests, failures: failures}) do
    "#{doctests} doctests, #{tests} tests, #{failures} failures"
  end

  defp credo_failure(log) do
    violations = credo_violations(log)
    totals = credo_totals(log)

    cond do
      violations != [] ->
        %{
          summary: credo_summary(totals, length(violations)),
          evidence: Enum.join(Enum.take(violations, 6), "; ")
        }

      totals ->
        %{summary: totals, evidence: totals}

      true ->
        nil
    end
  end

  defp credo_violations(log) do
    log
    |> String.split("\n")
    |> Enum.map(&clean_log_line/1)
    |> Enum.filter(&Regex.match?(~r/^\[[A-Z]\]\s+/, &1))
    |> Enum.map(&compact/1)
  end

  defp credo_totals(log) do
    case Regex.run(
           ~r/found\s+\d+\s+consistency issue[s]?,\s+\d+\s+warnings?,\s+\d+\s+refactoring opportunities,\s+\d+\s+code readability issues,\s+\d+\s+software design suggestions\./i,
           log
         ) do
      [match] -> compact(match)
      _ -> nil
    end
  end

  defp credo_summary(nil, count), do: "#{count} Credo issue(s)"
  defp credo_summary(totals, _count), do: "Credo failed: #{totals}"

  defp warnings(true), do: ["DBConnection ownership errors also appeared in the log"]
  defp warnings(false), do: []

  defp first_failure(log) do
    cond do
      match = Regex.run(~r/##\[error\]\s*(.+)/, log) ->
        match |> List.last() |> compact()

      match = Regex.run(~r/\*\* \(([^)]+)\)\s*([^\n]+)/, log) ->
        match |> List.delete_at(0) |> Enum.join(": ") |> compact()

      true ->
        ""
    end
  end

  defp evidence(parts) when is_list(parts) do
    parts
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&compact/1)
    |> Enum.join("; ")
  end

  defp clean_log_line(line) do
    line
    |> String.replace(~r/^\d{4}-\d{2}-\d{2}T\S+\s+/, "")
    |> String.replace("##[warning]", "")
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.replace(~r/^[┃│\s]+/u, "")
    |> String.trim()
  end

  defp compact(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/\s*\R\s*/, " ")
    |> truncate(500)
  end

  defp truncate(value, max_size) when byte_size(value) <= max_size, do: value
  defp truncate(value, max_size), do: binary_part(value, 0, max_size) <> "..."
end
