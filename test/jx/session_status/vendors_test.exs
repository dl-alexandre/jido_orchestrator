defmodule JX.SessionStatus.VendorsTest do
  use ExUnit.Case, async: true

  alias JX.SessionStatus
  alias JX.SessionStatus.Vendors

  @moduledoc """
  Regression net for vendor terminal-UI drift.

  Each vendor in `JX.SessionStatus.Vendors.fixtures/0` ships
  representative scrollback snapshots paired with the work state
  `SessionStatus.analyze/2` should derive. When an agent CLI ships a
  UI change that would silently turn a known classification into
  `unknown`, this test fails loudly and points at the specific fixture.

  Adding a new fixture is the protocol for capturing a new agent UI
  shape — see `JX.SessionStatus.Vendors`'s moduledoc.
  """

  describe "verified_versions/0" do
    test "lists every vendor we have a fixture corpus for" do
      versions = Vendors.verified_versions()
      fixtures = Vendors.fixtures()

      assert MapSet.new(Map.keys(versions)) == MapSet.new(Map.keys(fixtures)),
             "verified_versions/0 and fixtures/0 must cover the same vendor set; " <>
               "version keys: #{inspect(Map.keys(versions))}, fixture keys: #{inspect(Map.keys(fixtures))}"
    end

    test "each version tag is a non-empty string" do
      for {vendor, version} <- Vendors.verified_versions() do
        assert is_binary(version) and version != "",
               "vendor #{inspect(vendor)} has invalid version tag #{inspect(version)}"
      end
    end
  end

  describe "fixtures/0 corpus" do
    test "every fixture has a non-empty output and a valid expected_state" do
      valid_states = MapSet.new(SessionStatus.work_states())

      for {vendor, fixture} <- Vendors.all_fixtures() do
        assert is_binary(fixture.output) and fixture.output != "",
               "vendor #{inspect(vendor)} fixture #{inspect(fixture.note)} has empty output"

        assert MapSet.member?(valid_states, fixture.expected_state),
               "vendor #{inspect(vendor)} fixture #{inspect(fixture.note)} has invalid " <>
                 "expected_state #{inspect(fixture.expected_state)}; valid: " <>
                 inspect(SessionStatus.work_states())
      end
    end

    test "every fixture has a note describing what it's pinning" do
      for {vendor, fixture} <- Vendors.all_fixtures() do
        assert is_binary(fixture.note) and fixture.note != "",
               "vendor #{inspect(vendor)} fixture is missing a note"
      end
    end

    test "each vendor contributes at least one fixture" do
      for {vendor, list} <- Vendors.fixtures() do
        assert is_list(list) and list != [],
               "vendor #{inspect(vendor)} has no fixtures; add one before declaring " <>
                 "the vendor verified"
      end
    end
  end

  describe "analyze/2 against fixture corpus" do
    # Generates a focused test per vendor + fixture so a regression points
    # straight at the offending sample.
    for {vendor, fixtures} <- Vendors.fixtures(), fixture <- fixtures do
      @vendor vendor
      @fixture fixture

      test "#{vendor}: #{fixture.note}" do
        result = SessionStatus.analyze(%{}, %{status: "ok", output: @fixture.output})

        assert result.work_state == @fixture.expected_state, """
        Vendor UI drift detected for #{@vendor} (#{inspect(@fixture.note)}).

        Expected work_state: #{@fixture.expected_state}
        Got:                 #{result.work_state}

        Output that no longer classifies correctly:
        ----------------------------------------------------------------
        #{@fixture.output}
        ----------------------------------------------------------------

        If the vendor changed its UI, update the patterns in
        JX.SessionStatus and bump the version in
        JX.SessionStatus.Vendors.verified_versions/0.
        """
      end
    end
  end
end
