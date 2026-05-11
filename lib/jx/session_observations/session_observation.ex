defmodule JX.SessionObservations.SessionObservation do
  @moduledoc """
  Persisted read-only observation of a discovered session snapshot.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias JX.SessionStatus

  @capture_statuses ~w(ok error skipped)

  @type t :: %__MODULE__{}

  schema "session_observations" do
    field(:ref, :string)
    field(:host, :string)
    field(:transport, :string)
    field(:type, :string)
    field(:state, :string)
    field(:kind, :string)
    field(:agent_name, :string, default: "")
    field(:task_id, :string, default: "")
    field(:tmux_server, :string, default: "")
    field(:session_name, :string, default: "")
    field(:window, :integer)
    field(:pane, :integer)
    field(:pid, :integer)
    field(:ssh_target, :string, default: "")
    field(:work_state, :string)
    field(:capture_status, :string)
    field(:summary, :string, default: "")
    field(:snapshot, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(observation, attrs) do
    observation
    |> cast(attrs, [
      :ref,
      :host,
      :transport,
      :type,
      :state,
      :kind,
      :agent_name,
      :task_id,
      :tmux_server,
      :session_name,
      :window,
      :pane,
      :pid,
      :ssh_target,
      :work_state,
      :capture_status,
      :summary,
      :snapshot
    ])
    |> update_change(:ref, &trim/1)
    |> update_change(:host, &trim/1)
    |> update_change(:transport, &trim/1)
    |> update_change(:type, &trim/1)
    |> update_change(:state, &trim/1)
    |> update_change(:kind, &trim/1)
    |> update_change(:agent_name, &trim/1)
    |> update_change(:task_id, &trim/1)
    |> update_change(:tmux_server, &trim/1)
    |> update_change(:session_name, &trim/1)
    |> update_change(:ssh_target, &trim/1)
    |> update_change(:work_state, &trim/1)
    |> update_change(:capture_status, &trim/1)
    |> update_change(:summary, &trim/1)
    |> validate_required([
      :ref,
      :host,
      :transport,
      :type,
      :state,
      :work_state,
      :capture_status,
      :snapshot
    ])
    |> validate_inclusion(:work_state, SessionStatus.work_states())
    |> validate_inclusion(:capture_status, @capture_statuses)
    |> validate_number(:window, greater_than_or_equal_to: 0)
    |> validate_number(:pane, greater_than_or_equal_to: 0)
    |> validate_number(:pid, greater_than: 0)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
