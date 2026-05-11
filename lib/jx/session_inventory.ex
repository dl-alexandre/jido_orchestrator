defmodule JX.SessionInventory do
  @moduledoc """
  Builds a unified management view from tmux panes, processes, tasks, and SSH sessions.
  """

  alias JX.Redaction

  @agent_kinds ~w(codex claude opencode)
  @stream_adopt_roles ~w(cli desktop server)

  def build(activity_report, ssh_sessions, tasks) do
    ssh_by_pane = ssh_sessions_by_pane(ssh_sessions)
    ssh_by_pid = ssh_sessions_by_pid(ssh_sessions)
    tasks_by_pane = tasks_by_pane(tasks)

    entries =
      activity_report.activity
      |> Enum.map(&activity_entry(&1, ssh_by_pane, ssh_by_pid, tasks_by_pane))
      |> Kernel.++(unmatched_ssh_entries(ssh_sessions, activity_report.activity))
      |> Enum.map(&with_ref/1)
      |> Enum.sort_by(&sort_key/1)

    %{sessions: entries, errors: activity_report.errors}
  end

  def filter(sessions, opts \\ []) do
    sessions
    |> filter_type(Keyword.get(opts, :type))
    |> filter_action(Keyword.get(opts, :action))
    |> filter_ssh_target(Keyword.get(opts, :ssh_target))
  end

  def find(sessions, ref) do
    Enum.find(sessions, &(&1.ref == ref))
  end

  def ref_for(entry) do
    source =
      if tmux_entry?(entry) do
        "tmux:#{entry.host}:#{entry.server}:#{entry.session}:#{entry.window}:#{entry.pane}"
      else
        "process:#{entry.host}:#{process_ref_identity(entry)}:#{entry.command}"
      end

    "s-" <> short_hash(source)
  end

  def probe_requires_force?(%{type: "ssh"} = entry) do
    active_or_foreground?(entry) or agent_ui_hint?(entry)
  end

  def probe_requires_force?(_entry), do: false

  def probe_runs_in_agent_ui?(%{type: "ssh"} = entry), do: agent_ui_hint?(entry)
  def probe_runs_in_agent_ui?(_entry), do: false

  defp activity_entry(entry, ssh_by_pane, ssh_by_pid, tasks_by_pane) do
    ssh_session = Map.get(ssh_by_pane, pane_key(entry)) || Map.get(ssh_by_pid, entry.process_pid)
    task = Map.get(tasks_by_pane, task_pane_key(entry))
    kind = entry.kind || ""

    %{
      host: entry.host,
      transport: entry.transport,
      type: session_type(entry, ssh_session, task),
      state: session_state(task),
      server: entry.server,
      session: entry.session,
      window: entry.window,
      pane: entry.pane,
      tty: entry.tty,
      active: entry.active,
      kind: kind,
      process_role: Map.get(entry, :process_role, ""),
      resume_available: Map.get(entry, :resume_available, false),
      resume_ref: Map.get(entry, :resume_ref, ""),
      zed_workspace: Map.get(entry, :zed_workspace, ""),
      pid: entry.process_pid || (ssh_session && ssh_session.pid),
      ppid: Map.get(entry, :process_ppid),
      stat: entry.process_stat,
      command: activity_command(entry),
      current_path: entry.current_path,
      title: entry.title,
      ssh_target: (ssh_session && ssh_session.target) || "",
      registered_host: (ssh_session && ssh_session.registered_host) || "",
      task_id: (task && task.task_id) || "",
      project: task_project(task),
      agent_name: task_agent_name(task, kind),
      actions: actions(entry, ssh_session, task)
    }
  end

  defp filter_type(sessions, nil), do: sessions
  defp filter_type(sessions, type), do: Enum.filter(sessions, &(&1.type == type))

  defp filter_action(sessions, nil), do: sessions

  defp filter_action(sessions, action) do
    Enum.filter(sessions, fn session ->
      session.actions
      |> String.split(",", trim: true)
      |> Enum.member?(action)
    end)
  end

  defp filter_ssh_target(sessions, nil), do: sessions
  defp filter_ssh_target(sessions, target), do: Enum.filter(sessions, &(&1.ssh_target == target))

  defp unmatched_ssh_entries(ssh_sessions, activity) do
    activity_pids =
      activity
      |> Enum.map(& &1.process_pid)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    ssh_sessions
    |> Enum.reject(&tmux_pane?/1)
    |> Enum.reject(&MapSet.member?(activity_pids, &1.pid))
    |> Enum.map(fn session ->
      %{
        host: "local",
        transport: "local",
        type: "ssh",
        state: "unmanaged",
        server: "",
        session: "",
        window: nil,
        pane: nil,
        tty: session.tty,
        active: nil,
        kind: "ssh",
        process_role: "process",
        resume_available: false,
        resume_ref: "",
        zed_workspace: "",
        pid: session.pid,
        ppid: nil,
        stat: session.stat,
        command: session.command,
        current_path: "",
        title: "",
        ssh_target: session.target,
        registered_host: session.registered_host,
        task_id: "",
        project: "",
        agent_name: "",
        actions: "inspect"
      }
    end)
  end

  defp session_type(_entry, _ssh_session, task) when not is_nil(task), do: "task"
  defp session_type(_entry, ssh_session, _task) when not is_nil(ssh_session), do: "ssh"
  defp session_type(%{kind: kind}, _ssh_session, _task) when kind in @agent_kinds, do: "agent"

  defp session_type(%{server: server, session: session}, _ssh_session, _task)
       when server not in [nil, ""] and session not in [nil, ""] do
    "tmux"
  end

  defp session_type(_entry, _ssh_session, _task), do: "process"

  defp session_state(nil), do: "unmanaged"
  defp session_state(task), do: task.status

  defp actions(entry, ssh_session, task) do
    []
    |> maybe_add(task != nil, ["task-send", "logs", "stop"])
    |> maybe_add(tmux_entry?(entry), ["attach", "capture"])
    |> maybe_add(safe_ssh_probe?(entry, ssh_session), [
      "pane-probe"
    ])
    |> maybe_add(force_ssh_probe?(entry, ssh_session), [
      "force-probe"
    ])
    |> maybe_add(ssh_session != nil and not tmux_entry?(entry), ["inspect"])
    |> maybe_add(process_only_agent?(entry, task), ["inspect"])
    |> maybe_add(resume_adoptable?(entry, task), ["resume-adopt"])
    |> maybe_add(stream_adoptable?(entry, task), ["inspect", "stream-adopt"])
    |> maybe_add(task == nil and adoptable?(entry), ["adopt"])
    |> maybe_add(sendable?(entry, task), ["send"])
    |> Enum.uniq()
    |> Enum.join(",")
  end

  defp maybe_add(actions, true, values), do: actions ++ values
  defp maybe_add(actions, false, _values), do: actions

  defp adoptable?(entry) do
    tmux_entry?(entry) and entry.current_path not in [nil, ""]
  end

  defp stream_adoptable?(entry, nil) do
    not tmux_entry?(entry) and entry.kind in @agent_kinds and
      stream_adoptable_role?(Map.get(entry, :process_role, ""))
  end

  defp stream_adoptable?(_entry, _task), do: false

  defp stream_adoptable_role?(""), do: true
  defp stream_adoptable_role?(role), do: role in @stream_adopt_roles

  defp resume_adoptable?(entry, nil) do
    not tmux_entry?(entry) and entry.kind in @agent_kinds and
      Map.get(entry, :resume_available, false)
  end

  defp resume_adoptable?(_entry, _task), do: false

  defp process_only_agent?(entry, nil) do
    not tmux_entry?(entry) and entry.kind in @agent_kinds
  end

  defp process_only_agent?(_entry, _task), do: false

  defp sendable?(entry, task) do
    task != nil or (tmux_entry?(entry) and (entry.kind in @agent_kinds or agent_ui_hint?(entry)))
  end

  defp safe_ssh_probe?(entry, ssh_session) do
    ssh_session != nil and tmux_entry?(entry) and not risky_ssh_probe?(entry) and
      not agent_ui_ssh_probe?(entry)
  end

  defp force_ssh_probe?(entry, ssh_session) do
    ssh_session != nil and tmux_entry?(entry) and risky_ssh_probe?(entry) and
      not agent_ui_ssh_probe?(entry)
  end

  defp risky_ssh_probe?(entry) do
    entry = Map.put(entry, :type, "ssh")
    probe_requires_force?(entry)
  end

  defp agent_ui_ssh_probe?(entry) do
    entry = Map.put(entry, :type, "ssh")
    probe_runs_in_agent_ui?(entry)
  end

  defp active_or_foreground?(entry) do
    case Map.fetch(entry, :active) do
      {:ok, true} -> true
      {:ok, false} -> false
      _missing_or_nil -> foreground_stat?(Map.get(entry, :stat))
    end
  end

  defp foreground_stat?(stat) when is_binary(stat), do: String.contains?(stat, "+")
  defp foreground_stat?(_stat), do: false

  defp agent_ui_hint?(entry) do
    text =
      [
        Map.get(entry, :title),
        Map.get(entry, :current_path),
        Map.get(entry, :command) || Map.get(entry, :process_command) ||
          Map.get(entry, :pane_command)
      ]
      |> Enum.join(" ")
      |> String.downcase()

    Enum.any?(
      ["claude", "opencode", "codex", "openai", "gpt-", "oc |", "✳"],
      &String.contains?(text, &1)
    )
  end

  defp tmux_entry?(entry) do
    entry.server not in [nil, ""] and entry.session not in [nil, ""] and is_integer(entry.window) and
      is_integer(entry.pane)
  end

  defp tmux_pane?(session) do
    session.server not in [nil, ""] and session.session not in [nil, ""] and
      is_integer(session.window) and is_integer(session.pane)
  end

  defp process_ref_identity(entry) do
    tty = Map.get(entry, :tty)

    cond do
      Map.get(entry, :type) == "ssh" and Map.get(entry, :pid) not in [nil, ""] ->
        ["ssh", Map.get(entry, :ssh_target, ""), Map.get(entry, :pid)]
        |> Enum.join(":")

      is_binary(tty) and tty not in ["", "??"] ->
        tty

      true ->
        Map.get(entry, :pid, "")
    end
  end

  defp ssh_sessions_by_pane(ssh_sessions) do
    ssh_sessions
    |> Enum.filter(&tmux_pane?/1)
    |> Map.new(&{pane_key(&1), &1})
  end

  defp ssh_sessions_by_pid(ssh_sessions) do
    Map.new(ssh_sessions, &{&1.pid, &1})
  end

  defp tasks_by_pane(tasks) do
    Map.new(tasks, &{task_pane_key(&1), &1})
  end

  defp pane_key(entry) do
    {entry.server, entry.session, entry.window, entry.pane}
  end

  defp task_pane_key(%{host: %{name: host_name}} = task) do
    {host_name, task.tmux_server, task.session_name, task.window, task.pane}
  end

  defp task_pane_key(entry) do
    {entry.host, entry.server, entry.session, entry.window, entry.pane}
  end

  defp task_project(nil), do: ""
  defp task_project(%{project: %{name: name}}), do: name
  defp task_project(_task), do: ""

  defp task_agent_name(nil, kind) when kind in @agent_kinds, do: kind
  defp task_agent_name(nil, _kind), do: ""
  defp task_agent_name(task, _kind), do: task.agent_name

  defp activity_command(%{process_command: command}) when command not in [nil, ""], do: command
  defp activity_command(%{pane_command: command}), do: command || ""

  defp sort_key(entry) do
    {
      entry.host,
      server_rank(entry.server),
      entry.server,
      entry.session,
      entry.window || -1,
      entry.pane || -1,
      process_role_sort_rank(entry),
      entry.pid || 0
    }
  end

  defp process_role_sort_rank(%{kind: kind, process_role: role}) when kind in @agent_kinds do
    process_role_rank(role)
  end

  defp process_role_sort_rank(_entry), do: 1

  defp process_role_rank(role) when role in @stream_adopt_roles, do: 0
  defp process_role_rank(""), do: 1
  defp process_role_rank("acp"), do: 2
  defp process_role_rank("remote-bridge"), do: 3
  defp process_role_rank(_role), do: 4

  defp server_rank(server) do
    cond do
      server in [nil, ""] -> 0
      server == JX.Tmux.managed_server() -> 1
      true -> 2
    end
  end

  defp with_ref(entry) do
    entry
    |> Map.put(:ref, ref_for(entry))
    |> Map.update(:command, "", &Redaction.redact_command/1)
  end

  defp short_hash(source) do
    :sha256
    |> :crypto.hash(source)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 10)
  end
end
