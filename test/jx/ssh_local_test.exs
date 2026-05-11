defmodule JX.SSHLocalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JX.Hosts.Host
  alias JX.SSH.Local

  test "run captures command output and failure status" do
    host = %Host{transport: "local", workspace_path: "/tmp"}

    assert {:ok, "hello\n"} = Local.run(host, "printf 'hello\\n'")

    assert {:error, {:local_failed, 7, "bad\n"}} =
             Local.run(host, "printf 'bad\\n'; exit 7")
  end

  test "stream_log tails a local log file" do
    host = %Host{transport: "local", workspace_path: "/tmp"}

    log_path =
      Path.join(System.tmp_dir!(), "jx-local-log-#{System.unique_integer([:positive])}.log")

    File.write!(log_path, "one\ntwo\nthree\n")

    on_exit(fn -> File.rm(log_path) end)

    assert capture_io(fn ->
             assert :ok = Local.stream_log(host, log_path, lines: 2)
           end) == "two\nthree\n"

    assert capture_io(fn ->
             assert :ok =
                      Local.stream_log(host, Path.join(System.tmp_dir!(), "missing-jx-local.log"))
           end) == ""
  end

  test "attach streams tmux output and reports failed status" do
    with_fake_tmux("""
    #!/bin/sh
    if [ "$TMUX_MODE" = "fail" ]; then
      printf 'no session\\n'
      exit 3
    fi

    printf 'attached %s\\n' "$*"
    exit 0
    """)

    host = %Host{transport: "local", workspace_path: "/tmp"}

    assert capture_io(fn ->
             assert :ok = Local.attach(host, "jx_session", tmux_server: "srv")
           end) =~ "attached"

    System.put_env("TMUX_MODE", "fail")

    assert capture_io(fn ->
             assert {:error, {:attach_failed, 3}} =
                      Local.attach(host, "jx_session", tmux_server: "srv")
           end) == "no session\n"
  end

  defp with_fake_tmux(script) do
    tmp = Path.join(System.tmp_dir!(), "jx-fake-tmux-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    tmux_path = Path.join(tmp, "tmux")
    File.write!(tmux_path, script)
    File.chmod!(tmux_path, 0o755)

    old_path = System.get_env("PATH")
    System.put_env("PATH", tmp <> ":" <> (old_path || ""))

    on_exit(fn ->
      if old_path, do: System.put_env("PATH", old_path), else: System.delete_env("PATH")
      System.delete_env("TMUX_MODE")
      File.rm_rf(tmp)
    end)
  end
end
