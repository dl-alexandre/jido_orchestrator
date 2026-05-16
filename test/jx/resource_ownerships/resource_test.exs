defmodule JX.ResourceOwnerships.ResourceTest do
  use ExUnit.Case, async: true

  alias JX.ResourceOwnerships.Resource

  describe "constant accessors" do
    test "resource_types/0 exposes the known set" do
      assert "tmux_session" in Resource.resource_types()
      assert "worktree_path" in Resource.resource_types()
    end

    test "cleanup_policies/0 exposes the known set" do
      assert "kill_tmux_session" in Resource.cleanup_policies()
      assert "exempt" in Resource.cleanup_policies()
    end

    test "states/0 exposes the known set" do
      assert "created" in Resource.states()
      assert "stale" in Resource.states()
    end
  end

  describe "changeset/2" do
    defp valid_attrs(overrides \\ %{}) do
      Map.merge(
        %{
          resource_id: "res-1",
          owner_type: "project",
          owner_project: "my-app",
          resource_type: "tmux_session",
          resource_name: "agent-1",
          cleanup_policy: "kill_tmux_session",
          state: "created",
          metadata: "{}",
          created_at: DateTime.utc_now()
        },
        overrides
      )
    end

    test "valid attrs build a valid changeset" do
      cs = Resource.changeset(%Resource{}, valid_attrs())
      assert cs.valid?
    end

    test "trims surrounding whitespace in string fields" do
      cs =
        Resource.changeset(
          %Resource{},
          valid_attrs(%{owner_project: "  my-app  ", reason: "  no longer needed  "})
        )

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :owner_project) == "my-app"
      assert Ecto.Changeset.get_change(cs, :reason) == "no longer needed"
    end

    test "unknown :resource_type fails validate_inclusion" do
      cs = Resource.changeset(%Resource{}, valid_attrs(%{resource_type: "bogus"}))

      refute cs.valid?
      assert %{resource_type: ["is invalid"]} = errors_on(cs)
    end

    test "unknown :cleanup_policy fails validate_inclusion" do
      cs = Resource.changeset(%Resource{}, valid_attrs(%{cleanup_policy: "yolo"}))

      refute cs.valid?
      assert %{cleanup_policy: ["is invalid"]} = errors_on(cs)
    end

    test "unknown :state fails validate_inclusion" do
      cs = Resource.changeset(%Resource{}, valid_attrs(%{state: "phantom"}))

      refute cs.valid?
      assert %{state: ["is invalid"]} = errors_on(cs)
    end

    test "missing required field is rejected by validate_required" do
      cs = Resource.changeset(%Resource{}, valid_attrs() |> Map.delete(:resource_id))

      refute cs.valid?
      assert %{resource_id: ["can't be blank"]} = errors_on(cs)
    end

    test "trim/1 handles nil change values without crashing" do
      # update_change is a no-op for fields not in changes; loading the
      # struct with pre-set values and casting just the required ones
      # exercises the nil-branch of trim/1.
      cs =
        Resource.changeset(
          %Resource{owner_type: "project", state: "created"},
          valid_attrs()
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
