defmodule JX.Repo.Migrations.AddDelegationIntegrationReviewFields do
  use Ecto.Migration

  def change do
    alter table(:delegations) do
      add(:integration_status, :text, null: false, default: "pending")
      add(:integration_summary, :text, null: false, default: "")
      add(:reviewed_by, :text, null: false, default: "")
      add(:reviewed_at, :utc_datetime_usec)
    end

    create(index(:delegations, [:integration_status]))
    create(index(:delegations, [:reviewed_at]))
  end
end
