defmodule JX.MeetBridgeScriptsTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "meet bridge bin commands are executable" do
    for script <- ~w(meet-browser-realtime meet-consult-codex meet-speech-output) do
      path = Path.join([@root, "bin", script])
      assert File.exists?(path)
      assert {"", 0} = System.cmd("test", ["-x", path])
    end
  end

  test "meet audio bridge scripts are executable" do
    for script <-
          ~w(meet_audio_chat_bridge.sh meet_audio_stt_openai.swift meet_audio_stt_macos.swift) do
      path = Path.join([@root, "scripts", script])
      assert File.exists?(path)
      assert {"", 0} = System.cmd("test", ["-x", path])
    end
  end

  test "audio chat bridge fails clearly when OpenAI STT is selected without a key" do
    {output, status} =
      System.cmd(Path.join([@root, "scripts", "meet_audio_chat_bridge.sh"]), ["met-test"],
        env: [
          {"OPENAI_API_KEY", ""},
          {"JX_MEET_STT_CMD", Path.join([@root, "scripts", "meet_audio_stt_openai.swift"])}
        ],
        stderr_to_stdout: true
      )

    assert status == 78
    assert output =~ "OPENAI_API_KEY is required for OpenAI audio transcription"
  end

  test "browser realtime command has an idle fallback" do
    {output, status} =
      System.cmd(Path.join([@root, "bin", "meet-browser-realtime"]), [],
        env: [
          {"JX_MEET_BROWSER_AGENT_CMD", ""},
          {"JX_MEET_CAPTION_FILE", "/no/such/file"},
          {"JX_MEET_CHAT_INPUT", "/no/such/file"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0
    assert Jason.decode!(output)["status"] == "idle"
  end

  test "consult command has a no-codex fallback" do
    payload =
      Jason.encode!(%{
        session: %{meeting_uri: "https://meet.google.com/abc-mnop-xyz"},
        transcript: "Can you hear me?"
      })

    payload_path =
      Path.join(System.tmp_dir!(), "jx-meet-consult-test-#{System.unique_integer()}.json")

    Process.put(:payload_path, payload_path)
    File.write!(payload_path, payload)

    {output, status} =
      System.cmd(
        "sh",
        [
          "-c",
          "cat \"$1\" | \"$2\"",
          "sh",
          payload_path,
          Path.join([@root, "bin", "meet-consult-codex"])
        ],
        env: [{"CODEX_BIN", "/no/such/codex"}, {"PATH", "/usr/bin:/bin"}],
        stderr_to_stdout: true
      )

    assert status == 0
    assert Jason.decode!(output)["response"] =~ "Meet bridge"
  after
    if payload_path = Process.get(:payload_path), do: File.rm(payload_path)
  end
end
