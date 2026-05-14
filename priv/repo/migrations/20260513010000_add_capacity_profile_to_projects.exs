defmodule JX.Repo.Migrations.AddCapacityProfileToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      # Named preset ("elixir-phoenix", "rails", "nodejs", "go", "python-ml")
      # or nil to inherit the host default profile.
      add :capacity_profile, :string, null: true
    end
  end
end
