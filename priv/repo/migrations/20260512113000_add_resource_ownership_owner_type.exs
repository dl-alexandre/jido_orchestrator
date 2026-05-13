defmodule JX.Repo.Migrations.AddResourceOwnershipOwnerType do
  use Ecto.Migration

  def change do
    alter table(:resource_ownerships) do
      add(:owner_type, :text, null: false, default: "project")
    end

    create(index(:resource_ownerships, [:owner_type]))
  end
end
