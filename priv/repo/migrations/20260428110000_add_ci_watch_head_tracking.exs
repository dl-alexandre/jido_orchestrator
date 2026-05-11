defmodule JX.Repo.Migrations.AddCiWatchHeadTracking do
  use Ecto.Migration

  def change do
    alter table(:ci_watches) do
      add(:head_sha, :text, null: false, default: "")
      add(:last_head_sha, :text, null: false, default: "")
      add(:last_head_checked_at, :utc_datetime_usec)
    end

    create(index(:ci_watches, [:head_sha]))
  end
end
