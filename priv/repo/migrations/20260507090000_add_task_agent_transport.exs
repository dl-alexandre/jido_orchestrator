defmodule JX.Repo.Migrations.AddTaskAgentTransport do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add(:agent_transport, :text, null: false, default: "native")
    end
  end
end
