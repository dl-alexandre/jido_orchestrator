defmodule JX.Repo.Migrations.AddHostTransport do
  use Ecto.Migration

  def change do
    alter table(:hosts) do
      add :transport, :text, null: false, default: "ssh"
    end
  end
end
