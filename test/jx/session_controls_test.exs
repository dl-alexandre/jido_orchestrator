defmodule JX.SessionControlsTest do
  use ExUnit.Case, async: false

  alias JX.Repo
  alias JX.SessionControls
  alias JX.SessionControls.SessionControl

  setup do
    Repo.delete_all(SessionControl)
    :ok
  end

  test "apply_controls auto-ignores process-only SSH rows" do
    assert [
             %{
               control_mode: "ignored",
               control_note: "process-only SSH observation; auto-ignored"
             },
             %{control_mode: "uncontrolled"},
             %{control_mode: "uncontrolled"}
           ] =
             SessionControls.apply_controls([
               process_only_ssh_session(),
               ssh_pane_session(),
               agent_session()
             ])
  end

  test "explicit controls override process-only SSH defaults" do
    session = process_only_ssh_session()

    assert {:ok, _control} =
             SessionControls.upsert_session(session, "protected", note: "operator wants review")

    assert [%{control_mode: "protected", control_note: "operator wants review"}] =
             SessionControls.apply_controls([session])
  end

  defp process_only_ssh_session do
    %{
      ref: "s-process-ssh",
      host: "local",
      type: "ssh",
      kind: "ssh",
      process_role: "process",
      ssh_target: "build-box",
      server: "",
      session: "",
      window: nil,
      pane: nil,
      pid: 42,
      current_path: "",
      title: ""
    }
  end

  defp ssh_pane_session do
    %{
      ref: "s-ssh-pane",
      host: "local",
      type: "ssh",
      kind: "ssh",
      process_role: "process",
      ssh_target: "build-box",
      server: "default",
      session: "shell",
      window: 0,
      pane: 0,
      pid: 43,
      current_path: "/repo",
      title: "remote shell"
    }
  end

  defp agent_session do
    %{
      ref: "s-agent",
      host: "local",
      type: "agent",
      kind: "codex",
      process_role: "cli",
      ssh_target: "",
      server: "default",
      session: "agent",
      window: 0,
      pane: 1,
      pid: 44,
      current_path: "/repo",
      title: "Codex"
    }
  end
end
