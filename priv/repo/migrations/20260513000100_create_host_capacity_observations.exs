defmodule JX.Repo.Migrations.CreateHostCapacityObservations do
  use Ecto.Migration

  def change do
    create table(:host_capacity_observations) do
      add :host_name, :string, null: false

      # How many worktree sessions were active at snapshot time
      add :active_sessions, :integer, null: false, default: 0

      # Raw hardware readings at snapshot time (MB / cores)
      add :ram_total_mb, :integer, null: false
      add :ram_available_mb, :integer, null: false
      add :disk_total_mb, :integer, null: false
      add :disk_available_mb, :integer, null: false
      add :cpu_cores, :integer, null: false

      # 1-minute load average (fractional cores); NULL when unavailable
      add :load_avg_1m, :float, null: true

      # The capacity_limit that was in effect at observation time
      add :capacity_limit_at_observation, :integer, null: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:host_capacity_observations, [:host_name])
    create index(:host_capacity_observations, [:host_name, :inserted_at])
  end
end
