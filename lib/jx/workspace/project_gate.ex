defmodule JX.Workspace.ProjectGate do
  @moduledoc """
  Project-level promotion gate over repo gate results.

  This module does not duplicate repo gate policy. It aggregates the per-host
  decisions already produced by `JX.Workspace.repo_gate/2`.
  """

  def evaluate(project_name, %{instances: instances}) when is_list(instances) do
    hosts =
      instances
      |> Enum.map(&normalize_host/1)
      |> Enum.sort_by(&{&1.host, &1.repo_path})

    if hosts == [] do
      no_hosts(project_name)
    else
      eligible = Enum.all?(hosts, & &1.eligible)

      %{
        project: to_string(project_name),
        eligible: eligible,
        status: if(eligible, do: "allowed", else: "blocked"),
        hosts: hosts,
        reasons: aggregate_reasons(hosts),
        required_fixes: aggregate_required_fixes(hosts)
      }
    end
  end

  def evaluate(project_name, _repo_gate_report), do: no_hosts(project_name)

  def no_hosts(project_name) do
    %{
      project: to_string(project_name),
      eligible: false,
      status: "blocked",
      hosts: [],
      reasons: ["no_hosts_registered"],
      required_fixes: ["Register at least one host/repo for the project."]
    }
  end

  defp normalize_host(host) do
    eligible = field(host, :eligible, false) == true

    %{
      host: field(host, :host, ""),
      repo_path: field(host, :repo_path, ""),
      eligible: eligible,
      status: field(host, :status, if(eligible, do: "allowed", else: "blocked")),
      reasons: list_field(host, :reasons),
      required_fixes: list_field(host, :required_fixes),
      reconciliation_status: field(host, :reconciliation_status, "unknown"),
      trust_status: field(host, :trust_status, "unknown"),
      confidence: field(host, :confidence, "unknown"),
      drift_status: field(host, :drift_status, "unknown"),
      auth: auth_field(host)
    }
  end

  defp aggregate_reasons(hosts) do
    hosts
    |> Enum.flat_map(fn host ->
      Enum.map(host.reasons, &"#{host.host}:#{&1}")
    end)
    |> Enum.uniq()
  end

  defp aggregate_required_fixes(hosts) do
    hosts
    |> Enum.flat_map(fn host ->
      Enum.map(host.required_fixes, &"#{host.host}: #{&1}")
    end)
    |> Enum.uniq()
  end

  defp auth_field(host) do
    auth = field(host, :auth, %{})

    %{
      fetch_allowed: field(auth, :fetch_allowed, "unknown"),
      push_allowed: field(auth, :push_allowed, "unknown"),
      api_allowed: field(auth, :api_allowed, "unknown")
    }
  end

  defp list_field(map, key) do
    case field(map, key, []) do
      values when is_list(values) -> Enum.map(values, &to_string/1)
      value when value in [nil, ""] -> []
      value -> [to_string(value)]
    end
  end

  defp field(map, key, default) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, to_string(key)) -> Map.get(map, to_string(key))
      true -> default
    end
  end

  defp field(_value, _key, default), do: default
end
