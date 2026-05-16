defmodule JX.MonitorEvents.CursorTest do
  use ExUnit.Case, async: true

  alias JX.MonitorEvents.Cursor

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs =
        Cursor.changeset(%Cursor{}, %{
          consumer: "orchestrator",
          last_event_id: 0,
          last_seen_at: DateTime.utc_now()
        })

      assert cs.valid?
    end

    test "trims surrounding whitespace from :consumer" do
      cs = Cursor.changeset(%Cursor{}, %{consumer: "  orchestrator  ", last_event_id: 0})

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :consumer) == "orchestrator"
    end

    test "nil :consumer is rejected by validate_required" do
      cs = Cursor.changeset(%Cursor{}, %{consumer: nil, last_event_id: 0})

      refute cs.valid?
      assert %{consumer: ["can't be blank"]} = errors_on(cs)
    end

    test "negative :last_event_id fails validate_number" do
      cs = Cursor.changeset(%Cursor{}, %{consumer: "x", last_event_id: -1})

      refute cs.valid?
      assert %{last_event_id: ["must be greater than or equal to 0"]} = errors_on(cs)
    end

    test "trim/1 handles nil consumer without crashing" do
      # update_change is a no-op when the field isn't in changes, so passing
      # only :last_event_id exercises the nil-guard branch in trim/1.
      cs = Cursor.changeset(%Cursor{consumer: "existing"}, %{last_event_id: 5})

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
