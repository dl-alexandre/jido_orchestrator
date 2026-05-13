defmodule JX.Repo.Migrations.AddCapacityLimitToHosts do
  use Ecto.Migration

  def change do
    alter table(:hosts) do
      # Operator-set ceiling on concurrent worktree sessions for this host.
      # NULL means fall back to the hardware-probed formula.
      add :capacity_limit, :integer, null: true
    end
  end
end
