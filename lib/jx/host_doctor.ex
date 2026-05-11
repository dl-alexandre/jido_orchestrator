defmodule JX.HostDoctor do
  @moduledoc """
  Preflight checks for host runtime setup.
  """

  alias JX.AgentRunner
  alias JX.Hosts.Host
  alias JX.SSH
  alias JX.Shell
  alias JX.Tmux

  def run(%Host{} = host, opts \\ []) do
    agents = Keyword.get(opts, :agents, AgentRunner.agent_names())
    agent_transport = Keyword.get(opts, :agent_transport, AgentRunner.default_agent_transport())
    execution = group("execution", [check_execution(host)])

    groups =
      if failed?(execution) do
        [
          execution,
          skipped_group("workspace", "command execution failed"),
          skipped_group("tools", "command execution failed"),
          skipped_group("repositories", "command execution failed"),
          skipped_group("agents", "command execution failed"),
          skipped_group("tmux", "command execution failed")
        ]
      else
        [
          execution,
          group("workspace", workspace_checks(host)),
          group("tools", tool_checks(host)),
          group("repositories", repository_checks(host)),
          group("agents", agent_checks(host, agents, agent_transport)),
          group("tmux", tmux_checks(host))
        ]
      end

    %{host: host, groups: groups}
  end

  def passed?(%{groups: groups}) do
    Enum.all?(groups, fn group ->
      Enum.all?(group.checks, &(&1.status in [:ok, :skip]))
    end)
  end

  defp check_execution(host) do
    check_script(host, "can execute command", "printf agent-doctor-ok", "command execution works")
  end

  defp workspace_checks(host) do
    workspace = Shell.quote(host.workspace_path)
    temp_name = ".jx-doctor-#{unique_id()}"

    [
      check_script(
        host,
        "workspace exists or can be created",
        """
        set -eu
        workspace=#{workspace}
        mkdir -p "$workspace"
        test -d "$workspace"
        test -w "$workspace"
        printf %s "$workspace"
        """,
        host.workspace_path
      ),
      check_script(
        host,
        "can create/delete temp file in workspace",
        """
        set -eu
        workspace=#{workspace}
        mkdir -p "$workspace"
        tmp="$workspace/#{temp_name}"
        printf jx-doctor-ok > "$tmp"
        test "$(cat "$tmp")" = jx-doctor-ok
        rm -f "$tmp"
        test ! -e "$tmp"
        printf %s "$tmp"
        """,
        temp_name
      )
    ]
  end

  defp tool_checks(host) do
    [
      check_script(host, "git available", "command -v git && git --version"),
      check_script(host, "tmux available", "command -v tmux && tmux -V")
    ]
  end

  defp repository_checks(%Host{projects: []}) do
    [skip("registered repositories", "no projects registered for host")]
  end

  defp repository_checks(%Host{projects: projects} = host) do
    Enum.flat_map(projects, fn project ->
      repo = Shell.quote(project.repo_path)

      [
        check_script(
          host,
          "#{project.name}: repo path exists",
          "test -e #{repo} && printf %s #{repo}",
          project.repo_path
        ),
        check_script(
          host,
          "#{project.name}: repo is a git repository",
          "git -C #{repo} rev-parse --show-toplevel"
        ),
        check_script(
          host,
          "#{project.name}: git worktree supported",
          "git -C #{repo} worktree list --porcelain >/dev/null && printf supported",
          "supported"
        ),
        check_script(
          host,
          "#{project.name}: default remote reachable",
          """
          set -eu
          repo=#{repo}
          remote="$(git -C "$repo" remote 2>/dev/null | head -n 1 || true)"
          test -n "$remote"
          git -C "$repo" ls-remote "$remote" HEAD >/dev/null
          printf %s "$remote"
          """
        ),
        check_script(
          host,
          "#{project.name}: working tree clean",
          """
          set -eu
          repo=#{repo}
          test -z "$(git -C "$repo" status --porcelain)"
          printf clean
          """,
          "clean"
        )
      ]
    end)
  end

  defp agent_checks(host, agents, "native") do
    Enum.map(agents, fn agent_name ->
      check_script(
        host,
        "#{agent_name}: binary available",
        AgentRunner.binary_check_script(agent_name)
      )
    end)
  end

  defp agent_checks(host, agents, "acpx") do
    [
      check_script(host, "acpx: binary available", AgentRunner.acpx_binary_check_script()),
      check_script(host, "acpx: config readable", acpx_config_script(host), "config readable")
      | Enum.map(agents, fn agent_name ->
          check_script(
            host,
            "#{agent_name}: binary available for acpx adapter",
            AgentRunner.binary_check_script(agent_name)
          )
        end)
    ]
  end

  defp agent_checks(_host, _agents, agent_transport) do
    [fail("agent transport", "unsupported agent transport #{inspect(agent_transport)}")]
  end

  defp acpx_config_script(host) do
    cwd = Shell.quote(host.workspace_path)
    acpx = Shell.quote(AgentRunner.acpx_binary())

    """
    set -eu
    cwd=#{cwd}
    mkdir -p "$cwd"
    #{acpx} --cwd "$cwd" config show >/dev/null
    printf "config readable"
    """
  end

  defp tmux_checks(host) do
    session = "agent_doctor_#{unique_id()}"
    target = Tmux.target(session)

    [
      check_script(
        host,
        "can create/list/kill a temporary tmux session",
        """
        set -eu
        session=#{Shell.quote(session)}
        target=#{Shell.quote(target)}
        trap '#{Tmux.command()} kill-session -t "$target" 2>/dev/null || true' EXIT
        #{Tmux.command()} new-session -d -s "$session"
        #{Tmux.command()} has-session -t "$target"
        #{Tmux.command()} list-sessions >/dev/null
        #{Tmux.command()} kill-session -t "$target"
        trap - EXIT
        printf %s "$session"
        """,
        session
      )
    ]
  end

  defp check_script(host, name, script, ok_detail \\ nil) do
    case SSH.adapter(host).run(host, script) do
      {:ok, output} ->
        ok(name, ok_detail || trim_output(output))

      {:error, reason} ->
        fail(name, format_failure(reason))
    end
  end

  defp group(name, checks), do: %{name: name, checks: checks}

  defp skipped_group(name, reason) do
    group(name, [skip("all checks", reason)])
  end

  defp ok(name, detail), do: %{name: name, status: :ok, detail: detail}
  defp fail(name, detail), do: %{name: name, status: :fail, detail: detail}
  defp skip(name, detail), do: %{name: name, status: :skip, detail: detail}

  defp failed?(group) do
    Enum.any?(group.checks, &(&1.status == :fail))
  end

  defp format_failure({:ssh_failed, status, output}) do
    "ssh exited #{status}: #{trim_output(output)}"
  end

  defp format_failure({:local_failed, status, output}) do
    "local command exited #{status}: #{trim_output(output)}"
  end

  defp format_failure(reason), do: inspect(reason)

  defp trim_output(output) do
    output
    |> to_string()
    |> String.trim()
    |> String.replace(~r/\s*\R\s*/, "; ")
    |> truncate(600)
  end

  defp truncate(value, max_size) when byte_size(value) <= max_size, do: value
  defp truncate(value, max_size), do: binary_part(value, 0, max_size) <> "..."

  defp unique_id do
    6
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
