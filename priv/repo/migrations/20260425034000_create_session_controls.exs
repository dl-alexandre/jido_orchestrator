defmodule JX.Repo.Migrations.CreateSessionControls do
  use Ecto.Migration

  def change do
    create table(:session_controls) do
      add :ref, :text, null: false
      add :mode, :text, null: false
      add :project, :text, null: false, default: ""
      add :note, :text, null: false, default: ""
      add :host, :text, null: false, default: ""
      add :type, :text, null: false, default: ""
      add :kind, :text, null: false, default: ""
      add :ssh_target, :text, null: false, default: ""
      add :tmux_server, :text, null: false, default: ""
      add :session_name, :text, null: false, default: ""
      add :window, :integer
      add :pane, :integer
      add :pid, :integer
      add :current_path, :text, null: false, default: ""
      add :title, :text, null: false, default: ""
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:session_controls, [:ref])
    create index(:session_controls, [:mode])
    create index(:session_controls, [:project])
    create index(:session_controls, [:ssh_target])
  end
end
