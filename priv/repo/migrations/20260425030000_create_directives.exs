defmodule JX.Repo.Migrations.CreateDirectives do
  use Ecto.Migration

  def change do
    create table(:directives) do
      add :directive_id, :text, null: false
      add :target_type, :text, null: false
      add :task_ref, :text, null: false, default: ""
      add :tmux_server, :text, null: false
      add :session_name, :text, null: false
      add :window, :integer, null: false, default: 0
      add :pane, :integer, null: false, default: 0
      add :message, :text, null: false
      add :enter, :boolean, null: false, default: true
      add :status, :text, null: false
      add :error, :text, null: false, default: ""
      add :host_id, references(:hosts, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:directives, [:directive_id])
    create index(:directives, [:host_id])
    create index(:directives, [:task_ref])
    create index(:directives, [:status])
  end
end
