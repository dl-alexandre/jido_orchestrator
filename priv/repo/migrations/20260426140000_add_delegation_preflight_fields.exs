defmodule JX.Repo.Migrations.AddDelegationPreflightFields do
  use Ecto.Migration

  def change do
    alter table(:delegations) do
      add(:write_paths, :text, null: false, default: "[]")
      add(:forbidden_paths, :text, null: false, default: "[]")
      add(:lint_warnings, :text, null: false, default: "[]")
    end
  end
end
