defmodule JX.Repo.Migrations.AddSessionObservationsRefIdIndex do
  use Ecto.Migration

  # Backs list_changes / list_stale / list_observations, all of which filter
  # by :ref and order by id DESC. The existing (:ref) and (:inserted_at)
  # singletons can't serve the ORDER BY id phase as an index seek.
  def change do
    create(index(:session_observations, [:ref, :id]))
  end
end
