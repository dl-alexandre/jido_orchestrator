defmodule JX.Repo.Migrations.AddDelegationEvidenceFields do
  use Ecto.Migration

  def change do
    alter table(:delegations) do
      add(:evidence, :text, null: false, default: "[]")
      add(:residual_risks, :text, null: false, default: "[]")
    end
  end
end
