defmodule JX.Repo.Migrations.CreateSessionObservations do
  use Ecto.Migration

  def change do
    create table(:session_observations) do
      add :ref, :text, null: false
      add :host, :text, null: false
      add :transport, :text, null: false
      add :type, :text, null: false
      add :state, :text, null: false
      add :kind, :text, null: false
      add :agent_name, :text, null: false, default: ""
      add :task_id, :text, null: false, default: ""
      add :tmux_server, :text, null: false, default: ""
      add :session_name, :text, null: false, default: ""
      add :window, :integer
      add :pane, :integer
      add :pid, :integer
      add :ssh_target, :text, null: false, default: ""
      add :work_state, :text, null: false
      add :capture_status, :text, null: false
      add :summary, :text, null: false, default: ""
      add :snapshot, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:session_observations, [:ref])
    create index(:session_observations, [:host])
    create index(:session_observations, [:type])
    create index(:session_observations, [:work_state])
    create index(:session_observations, [:inserted_at])
  end
end
