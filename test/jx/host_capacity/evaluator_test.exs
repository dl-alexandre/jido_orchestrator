defmodule JX.HostCapacity.EvaluatorTest do
  use ExUnit.Case, async: false

  alias JX.HostCapacity.Evaluator
  alias JX.HostCapacity.Observation
  alias JX.Repo

  setup do
    Repo.delete_all(Observation)
    :ok
  end

  @profile %{
    name: "test-profile",
    ram_mb_per_slot: 3_072,
    disk_mb_per_slot: 2_048,
    cpu_cores_per_slot: 0.4
  }

  defp insert_observation(host_name, attrs) do
    defaults = %{
      host_name: host_name,
      active_sessions: 2,
      ram_total_mb: 16_384,
      ram_available_mb: 8_192,
      disk_total_mb: 204_800,
      disk_available_mb: 102_400,
      cpu_cores: 8,
      load_avg_1m: nil,
      capacity_limit_at_observation: nil
    }

    %Observation{}
    |> Observation.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  describe "evaluate/2 with insufficient data" do
    test "returns :insufficient_data when no observations exist" do
      result = Evaluator.evaluate("no-such-host", profile: @profile)

      assert result.verdict == :insufficient_data
      assert result.observations_analysed == 0
      assert result.suggested_limit == nil
    end

    test "returns :insufficient_data when fewer than 3 observations" do
      insert_observation("sparse-host", %{active_sessions: 1})
      insert_observation("sparse-host", %{active_sessions: 1})

      result = Evaluator.evaluate("sparse-host", profile: @profile)

      assert result.verdict == :insufficient_data
      assert result.observations_analysed == 2
    end
  end

  describe "evaluate/2 verdict: :hold" do
    test "holds when headroom per slot is within healthy range" do
      # 4 sessions running, 6144 MB available → 1536 MB/slot
      # pressure_ratio = 1536 / 3072 = 0.5 (exactly at boundary, should be :hold)
      for _ <- 1..5 do
        insert_observation("steady-host", %{
          active_sessions: 4,
          ram_available_mb: 6_144
        })
      end

      result = Evaluator.evaluate("steady-host", profile: @profile)

      assert result.verdict == :hold
      assert result.suggested_limit == nil
      assert result.observations_analysed == 5
    end
  end

  describe "evaluate/2 verdict: :raise" do
    test "recommends raising when headroom is well above profile" do
      # 1 session, 12288 MB available → 12288 MB/slot
      # pressure_ratio = 12288 / 3072 = 4.0  > 2.0 threshold
      for _ <- 1..5 do
        insert_observation("under-used-host", %{
          active_sessions: 1,
          ram_available_mb: 12_288
        })
      end

      result = Evaluator.evaluate("under-used-host", profile: @profile, current_limit: 4)

      assert result.verdict == :raise
      assert result.suggested_limit > 4
    end
  end

  describe "evaluate/2 verdict: :lower" do
    test "recommends lowering when headroom is below threshold" do
      # 4 sessions, 512 MB available → 128 MB/slot
      # pressure_ratio = 128 / 3072 ≈ 0.04 < 0.5 threshold
      for _ <- 1..5 do
        insert_observation("stressed-host", %{
          active_sessions: 4,
          ram_available_mb: 512
        })
      end

      result = Evaluator.evaluate("stressed-host", profile: @profile, current_limit: 4)

      assert result.verdict == :lower
      assert result.suggested_limit < 4
      assert result.suggested_limit >= 1
    end

    test "recommends lowering when CPU load is too high regardless of RAM" do
      # RAM is fine but load avg is 7.2 on 8 cores = 90% load ratio > 80% threshold
      for _ <- 1..5 do
        insert_observation("cpu-stressed-host", %{
          active_sessions: 1,
          ram_available_mb: 12_288,
          load_avg_1m: 7.2,
          cpu_cores: 8
        })
      end

      result = Evaluator.evaluate("cpu-stressed-host", profile: @profile, current_limit: 4)

      assert result.verdict == :lower
    end
  end

  describe "evaluate/2 result shape" do
    test "includes all expected keys" do
      for _ <- 1..5 do
        insert_observation("shaped-host", %{active_sessions: 2, ram_available_mb: 4_096})
      end

      result = Evaluator.evaluate("shaped-host", profile: @profile, current_limit: 3)

      assert Map.has_key?(result, :host)
      assert Map.has_key?(result, :observations_analysed)
      assert Map.has_key?(result, :avg_headroom_per_slot)
      assert Map.has_key?(result, :avg_load_ratio)
      assert Map.has_key?(result, :current_limit)
      assert Map.has_key?(result, :verdict)
      assert Map.has_key?(result, :suggested_limit)
      assert Map.has_key?(result, :reasoning)
      assert is_binary(result.reasoning)
    end
  end
end
