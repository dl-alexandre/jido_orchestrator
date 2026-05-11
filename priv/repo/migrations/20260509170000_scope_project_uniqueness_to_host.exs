defmodule JX.Repo.Migrations.ScopeProjectUniquenessToHost do
  use Ecto.Migration

  def change do
    drop_if_exists unique_index(:projects, [:name], name: :projects_name_index)
    drop_if_exists unique_index(:projects, [:slug], name: :projects_slug_index)

    create_if_not_exists unique_index(:projects, [:host_id, :name],
                           name: :projects_host_id_name_index
                         )

    create_if_not_exists unique_index(:projects, [:host_id, :slug],
                           name: :projects_host_id_slug_index
                         )
  end
end
