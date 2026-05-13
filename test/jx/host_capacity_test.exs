defmodule JX.HostCapacityTest do
  use ExUnit.Case, async: true

  alias JX.HostCapacity
  alias JX.Hosts.Host

  # SSH adapter is set to JX.SSH.Fake in test_helper.exs; fake returns defaults
  # for capacity scripts unless overridden via Process.put.

  defp local_host(name \\ "local") do
    %Host{name: name, transport: "local", ssh_target: nil, workspace_path: "/tmp/jx-test"}
  end

  describe "probe/1" do
    test "returns parsed resources from fake SSH" do
      # defaults: 16384 MB total / 8192 MB available RAM, 204800/102400 disk, 8 CPU cores
      {:ok, res} = HostCapacity.probe(local_host())

      assert res.ram_total_mb == 16_384
      assert res.ram_available_mb == 8_192
      assert res.disk_total_mb == 204_800
      assert res.disk_available_mb == 102_400
      assert res.cpu_cores == 8
    end

    test "overriding fake SSH values is reflected in result" do
      Process.put(:fake_ssh_capacity_ram, "32768 24576\n")
      Process.put(:fake_ssh_capacity_cpu, "16\n")

      {:ok, res} = HostCapacity.probe(local_host())

      assert res.ram_total_mb == 32_768
      assert res.ram_available_mb == 24_576
      assert res.cpu_cores == 16
    end
  end

  describe "assess/2" do
    test "computes recommended worktrees from default profile" do
      # 8192 MB RAM / 3072 per slot = 2
      # 102400 MB disk / 2048 per slot = 50
      # 8 cores / 0.4 per slot = 20
      # min(2, 50, 20) = 2
      {:ok, result} = HostCapacity.assess(local_host())

      assert result.host == "local"
      assert result.limits.by_ram == 2
      assert result.limits.by_disk == 50
      assert result.limits.by_cpu == 20
      assert result.recommended_worktrees == 2
    end

    test "profile override changes the recommendation" do
      # Override: 1 GB RAM per slot → 8192/1024 = 8, still min-capped by RAM
      profile = %{
        name: "custom",
        ram_mb_per_slot: 1_024,
        disk_mb_per_slot: 1_024,
        cpu_cores_per_slot: 1.0
      }

      {:ok, result} = HostCapacity.assess(local_host(), profile: profile)

      assert result.limits.by_ram == 8
      assert result.limits.by_disk == 100
      assert result.limits.by_cpu == 8
      assert result.recommended_worktrees == 8
    end

    test "recommended_worktrees is zero when available RAM is too low" do
      Process.put(:fake_ssh_capacity_ram, "3072 512\n")

      {:ok, result} = HostCapacity.assess(local_host())

      # 512 MB available / 3072 per slot = 0 (rounded down)
      assert result.limits.by_ram == 0
      assert result.recommended_worktrees == 0
    end

    test "result includes profile metadata" do
      {:ok, result} = HostCapacity.assess(local_host())

      assert result.profile.name == "elixir-phoenix-agent"
      assert result.profile.ram_mb_per_slot == 3_072
    end
  end

  describe "default_profile/0" do
    test "returns the Elixir/Phoenix agent profile" do
      profile = HostCapacity.default_profile()

      assert profile.name == "elixir-phoenix-agent"
      assert is_integer(profile.ram_mb_per_slot)
      assert is_integer(profile.disk_mb_per_slot)
      assert profile.cpu_cores_per_slot > 0
    end
  end
end
