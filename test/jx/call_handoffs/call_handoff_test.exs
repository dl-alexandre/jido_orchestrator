defmodule JX.CallHandoffs.CallHandoffTest do
  use ExUnit.Case, async: true

  alias JX.CallHandoffs.CallHandoff

  describe "constant accessors" do
    test "statuses/0 lists the lifecycle states" do
      assert "open" in CallHandoff.statuses()
      assert "applied" in CallHandoff.statuses()
      assert "closed" in CallHandoff.statuses()
    end

    test "surfaces/0 lists the supported call surfaces" do
      for surface <- ~w(call phone meet talk chat) do
        assert surface in CallHandoff.surfaces()
      end
    end
  end

  describe "changeset/2" do
    defp valid_attrs(overrides \\ %{}) do
      Map.merge(
        %{
          handoff_id: "handoff-1",
          surface: "call",
          status: "open",
          decisions: "[]",
          follow_ups: "[]",
          brief_snapshot: "{}",
          payload: "{}"
        },
        overrides
      )
    end

    test "valid attrs build a valid changeset" do
      cs = CallHandoff.changeset(%CallHandoff{}, valid_attrs())
      assert cs.valid?
    end

    test "trims string fields" do
      cs =
        CallHandoff.changeset(
          %CallHandoff{},
          valid_attrs(%{title: "  morning sync  ", project: "  my-app  "})
        )

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :title) == "morning sync"
      assert Ecto.Changeset.get_change(cs, :project) == "my-app"
    end

    test "unknown :status fails validate_inclusion" do
      cs = CallHandoff.changeset(%CallHandoff{}, valid_attrs(%{status: "weird"}))

      refute cs.valid?
      assert %{status: ["is invalid"]} = errors_on(cs)
    end

    test "unknown :surface fails validate_inclusion" do
      cs = CallHandoff.changeset(%CallHandoff{}, valid_attrs(%{surface: "telegram"}))

      refute cs.valid?
      assert %{surface: ["is invalid"]} = errors_on(cs)
    end

    test "missing :handoff_id is rejected by validate_required" do
      cs = CallHandoff.changeset(%CallHandoff{}, valid_attrs() |> Map.delete(:handoff_id))

      refute cs.valid?
      assert %{handoff_id: ["can't be blank"]} = errors_on(cs)
    end

    test "trim/1 handles nil change values without crashing" do
      # No string fields in attrs → update_change is a no-op, exercising
      # the nil-guard in trim/1.
      cs =
        CallHandoff.changeset(
          %CallHandoff{},
          valid_attrs() |> Map.put(:closed_at, DateTime.utc_now())
        )

      assert cs.valid?
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
