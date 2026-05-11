defmodule JX.Repo.Migrations.CreateRemoteSessionObservations do
  use Ecto.Migration

  def change do
    create table(:remote_session_observations) do
      add :local_ref, :text, null: false, default: ""
      add :ssh_target, :text, null: false, default: ""
      add :registered_host, :text, null: false, default: ""
      add :tmux_server, :text, null: false
      add :session_name, :text, null: false
      add :created_at, :utc_datetime_usec
      add :attached, :integer, null: false, default: 0
      add :windows, :integer, null: false, default: 0
      add :current_path, :text, null: false, default: ""
      add :recommendation_id, :text, null: false, default: ""
      add :probe_target, :text, null: false, default: ""

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:remote_session_observations, [:local_ref])
    create index(:remote_session_observations, [:ssh_target])
    create index(:remote_session_observations, [:tmux_server, :session_name])
    create index(:remote_session_observations, [:inserted_at])
  end
end
