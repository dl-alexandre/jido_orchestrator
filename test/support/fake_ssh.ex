defmodule JX.SSH.Fake do
  @moduledoc false

  @behaviour JX.SSH

  @impl true
  def run(host, script, _opts \\ []) do
    send(self(), {:ssh_script, script})

    cond do
      String.contains?(script, "jx-promotion-run") ->
        {:ok, fake_promotion_run(host, script)}

      String.contains?(script, "jx-repo-doctor") ->
        {:ok, fake_repo_doctor(host, script)}

      String.contains?(script, "jx-project-audit") ->
        {:ok, fake_project_audit(host)}

      String.contains?(script, "jx-discover-tmux-panes-all") ->
        {:ok,
         Process.get(
           :fake_ssh_tmux_pane_discovery,
           "jx\tjx_saysure_task_deadbeef_codex\t0\t0\t%1\t1\t/dev/pts/1\tcodex\t/srv/repos/saysure\tCodex\n"
         )}

      String.contains?(script, "jx-discover-tmux-all") ->
        {:ok,
         Process.get(
           :fake_ssh_tmux_discovery,
           "jx\tjx_saysure_task_deadbeef_codex\t1700000000\t0\t1\t/srv/repos/saysure\n"
         )}

      String.contains?(script, "list-panes -a -F") ->
        {:ok,
         Process.get(
           :fake_ssh_tmux_panes,
           "jx_saysure_task_deadbeef_codex\t0\t0\t%1\t1\t/dev/pts/1\tcodex\t/srv/repos/saysure\tCodex\n"
         )}

      String.contains?(script, "capture-pane") ->
        {:ok, Process.get(:fake_ssh_tmux_capture, "recent pane output\n")}

      String.contains?(script, "ps -axo pid,ppid,stat,tty,command") ->
        {:ok,
         Process.get(
           :fake_ssh_processes,
           """
             PID  PPID STAT TTY      COMMAND
             10      1 S+   pts/1    /usr/local/bin/codex exec
             11      1 S+   pts/2    ssh build-1-remote
             12      1 S    ??       /Applications/Codex.app/Contents/MacOS/Codex
           """
         )}

      String.contains?(script, "list-sessions -F") ->
        {:ok,
         Process.get(
           :fake_ssh_tmux_sessions,
           "jx_saysure_task_deadbeef_codex\t1700000000\t0\t1\t/srv/repos/saysure\n"
         )}

      String.contains?(script, "jx-adopt-inspect") ->
        {:ok, Process.get(:fake_ssh_adopt_output, "branch\tfeature/adopt\n")}

      String.contains?(script, "echo running") ->
        {:ok, Process.get(:fake_ssh_status_output, "running\n1700000000\nnone\n")}

      String.contains?(script, "jx-process-cwd") ->
        {:ok, Process.get(:fake_ssh_process_cwd, "/srv/repos/saysure\n")}

      # Host capacity probes
      String.contains?(script, "hw.memsize") ->
        {:ok, Process.get(:fake_ssh_capacity_ram, "16384 8192\n")}

      String.contains?(script, "df -m") ->
        {:ok, Process.get(:fake_ssh_capacity_disk, "204800 102400\n")}

      String.contains?(script, "hw.logicalcpu") ->
        {:ok, Process.get(:fake_ssh_capacity_cpu, "8\n")}

      true ->
        {:ok, "ready\n"}
    end
  end

  @impl true
  def attach(_host, session_name, opts \\ []) do
    send(self(), {:ssh_attach, session_name, opts})
    :ok
  end

  @impl true
  def stream_log(_host, log_path, opts \\ []) do
    send(self(), {:ssh_log, log_path, opts})
    :ok
  end

  defp fake_project_audit(host) do
    audits = Process.get(:fake_ssh_project_audits, %{})

    Map.get(audits, host.name, """
    jx-project-audit\t1
    repo_path\t#{host.workspace_path}/repo
    status\tok
    branch\tdevelop
    head\tabc123
    upstream\torigin/develop
    ahead_behind\t0\t0
    status_short_start
    ## develop...origin/develop
    status_short_end
    worktree_start
    worktree #{host.workspace_path}/repo
    HEAD abc123
    branch refs/heads/develop
    worktree_end
    """)
  end

  defp fake_repo_doctor(host, script) do
    reports = Process.get(:fake_ssh_repo_doctors, %{})
    repo_path = repo_path_from_script(script) || "#{host.workspace_path}/repo"

    Map.get(reports, host.name, """
    jx-repo-doctor\t1
    repo_path\t#{repo_path}
    status\tok
    branch\tdevelop
    head\tabc123
    upstream\torigin/develop
    remote\torigin
    remote_url\tgit@example.test:repo.git
    remote_refs_start
    abc123\trefs/heads/develop
    def456\trefs/heads/master
    remote_refs_end
    remote_status\t0
    status_short_start
    ## develop...origin/develop
    status_short_end
    worktree_start
    worktree #{repo_path}
    HEAD abc123
    branch refs/heads/develop
    worktree_end
    branches_start
    develop\torigin/develop\t\tabc123\tdevelop commit
    master\torigin/master\t\tdef456\tmaster commit
    branches_end
    """)
  end

  defp fake_promotion_run(host, script) do
    promotions = Process.get(:fake_ssh_promotions, %{})
    source = shell_assignment_from_script(script, "source") || "develop"
    target = shell_assignment_from_script(script, "target") || "master"

    Map.get(promotions, host.name, """
    jx-promotion-run\t1
    action\tfetch #{source} #{target}
    action\tcheckout #{target}
    action\tmerge --ff-only refs/remotes/origin/#{source}
    action\tpush #{target}
    status\tpromoted
    """)
  end

  defp repo_path_from_script(script) do
    case Regex.run(~r/repo='([^']+)'/, script) do
      [_, repo_path] -> repo_path
      _other -> nil
    end
  end

  defp shell_assignment_from_script(script, name) do
    case Regex.run(~r/#{Regex.escape(name)}='([^']+)'/, script) do
      [_, value] -> value
      _other -> nil
    end
  end
end
