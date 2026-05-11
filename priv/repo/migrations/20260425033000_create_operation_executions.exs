defmodule JX.Repo.Migrations.CreateOperationExecutions do
  use Ecto.Migration

  def change do
    create table(:operation_executions) do
      add :execution_id, :text, null: false
      add :requested, :text, null: false, default: ""
      add :recommendation_id, :text, null: false
      add :action, :text, null: false, default: ""
      add :safety, :text, null: false, default: ""
      add :ref, :text, null: false, default: ""
      add :target, :text, null: false, default: ""
      add :status, :text, null: false
      add :reason, :text, null: false, default: ""
      add :error, :text, null: false, default: ""
      add :result_summary, :text, null: false, default: ""
      add :result_snapshot, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:operation_executions, [:execution_id])
    create index(:operation_executions, [:recommendation_id])
    create index(:operation_executions, [:ref])
    create index(:operation_executions, [:action])
    create index(:operation_executions, [:status])
    create index(:operation_executions, [:inserted_at])
  end
end
