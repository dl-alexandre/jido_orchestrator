defmodule JX.Directives.Directive do
  @moduledoc """
  Audited instruction sent to an existing task or tmux pane.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias JX.Hosts.Host

  @statuses ~w(sent error)
  @target_types ~w(task tmux)

  @type t :: %__MODULE__{}

  schema "directives" do
    field(:directive_id, :string)
    field(:target_type, :string)
    field(:task_ref, :string, default: "")
    field(:tmux_server, :string)
    field(:session_name, :string)
    field(:window, :integer, default: 0)
    field(:pane, :integer, default: 0)
    field(:message, :string)
    field(:enter, :boolean, default: true)
    field(:status, :string)
    field(:error, :string, default: "")

    belongs_to(:host, Host)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(directive, attrs) do
    directive
    |> cast(attrs, [
      :directive_id,
      :target_type,
      :task_ref,
      :tmux_server,
      :session_name,
      :window,
      :pane,
      :message,
      :enter,
      :status,
      :error,
      :host_id
    ])
    |> update_change(:task_ref, &trim/1)
    |> update_change(:tmux_server, &trim/1)
    |> update_change(:session_name, &trim/1)
    |> update_change(:message, &trim/1)
    |> update_change(:error, &trim/1)
    |> validate_required([
      :directive_id,
      :target_type,
      :tmux_server,
      :session_name,
      :window,
      :pane,
      :message,
      :enter,
      :status,
      :host_id
    ])
    |> validate_inclusion(:target_type, @target_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:window, greater_than_or_equal_to: 0)
    |> validate_number(:pane, greater_than_or_equal_to: 0)
    |> assoc_constraint(:host)
    |> unique_constraint(:directive_id)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
