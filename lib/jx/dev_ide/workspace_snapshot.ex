defmodule JX.DevIDE.WorkspaceSnapshot do
  @moduledoc """
  Latest durable JX-side observation of one DevIDE workspace.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(healthy blocked needs_review unknown)

  @type t :: %__MODULE__{}

  schema "devide_workspace_snapshots" do
    field(:workspace_id, :string)
    field(:name, :string, default: "")
    field(:lifecycle_status, :string, default: "")
    field(:status, :string, default: "unknown")
    field(:mode, :string, default: "")
    field(:db_isolation, :string, default: "unknown")
    field(:attention_flags, :string, default: "[]")
    field(:snapshot, :string, default: "{}")
    field(:fingerprint, :string)
    field(:source_url, :string, default: "")
    field(:last_observed_at, :utc_datetime_usec)
    field(:last_changed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :workspace_id,
      :name,
      :lifecycle_status,
      :status,
      :mode,
      :db_isolation,
      :attention_flags,
      :snapshot,
      :fingerprint,
      :source_url,
      :last_observed_at,
      :last_changed_at
    ])
    |> trim_fields([
      :workspace_id,
      :name,
      :lifecycle_status,
      :status,
      :mode,
      :db_isolation,
      :attention_flags,
      :snapshot,
      :fingerprint,
      :source_url
    ])
    |> validate_required([
      :workspace_id,
      :status,
      :attention_flags,
      :snapshot,
      :fingerprint
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:workspace_id)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(to_string(value))
end
