defmodule JX.CLI.SupportTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Support

  test "validate_options returns a stable invalid option error" do
    assert :ok = Support.validate_options([])
    assert {:error, message} = Support.validate_options(bad: "value")
    assert message == ~s(invalid options: [bad: "value"])
  end

  test "expect_no_args returns usage when extra arguments remain" do
    assert :ok = Support.expect_no_args([], "jx thing")
    assert {:error, "usage: jx thing"} = Support.expect_no_args(["extra"], "jx thing")
  end

  test "print_json emits pretty JSON" do
    output = capture_io(fn -> Support.print_json(%{ok: true}) end)

    assert Jason.decode!(output) == %{"ok" => true}
    assert output =~ "\n"
  end

  test "print_table aligns columns" do
    output =
      capture_io(fn ->
        Support.print_table(["NAME", "VALUE"], [["short", "1"], ["longer", "2"]])
      end)

    assert output =~ "NAME"
    assert output =~ "longer"
  end
end
