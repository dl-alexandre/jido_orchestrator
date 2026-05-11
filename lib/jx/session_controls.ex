defmodule JX.SessionControls do
  @moduledoc """
  Persistent operator policy for discovered sessions.
  """

  import Ecto.Query

  alias JX.Repo
  alias JX.SessionControls.SessionControl

  @suppressed_modes ~w(ignored protected)

  def modes, do: SessionControl.modes()

  def upsert_session(session, mode, opts \\ []) do
    attrs =
      session
      |> attrs_from_session()
      |> Map.merge(%{
        mode: mode,
        project: Keyword.get(opts, :project, ""),
        note: Keyword.get(opts, :note, ""),
        last_seen_at: DateTime.utc_now()
      })

    %SessionControl{}
    |> SessionControl.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :mode,
           :project,
           :note,
           :host,
           :type,
           :kind,
           :ssh_target,
           :tmux_server,
           :session_name,
           :window,
           :pane,
           :pid,
           :current_path,
           :title,
           :last_seen_at,
           :updated_at
         ]},
      conflict_target: :ref
    )
  end

  def delete(ref) do
    case Repo.get_by(SessionControl, ref: ref) do
      nil -> {:error, :session_control_not_found}
      control -> Repo.delete(control)
    end
  end

  def list_controls(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    SessionControl
    |> maybe_filter_mode(Keyword.get(opts, :mode))
    |> order_by([control], desc: control.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def apply_controls(sessions) do
    controls = controls_by_ref()

    Enum.map(sessions, fn session ->
      case Map.get(controls, session.ref) do
        nil -> apply_default_control(session)
        control -> apply_control(session, control)
      end
    end)
  end

  def suppressed?(%{control_mode: mode}), do: mode in @suppressed_modes
  def suppressed?(_session), do: false

  def managed?(%{control_mode: "managed"}), do: true
  def managed?(_session), do: false

  def get(ref), do: Repo.get_by(SessionControl, ref: ref)

  defp controls_by_ref do
    SessionControl
    |> Repo.all()
    |> Map.new(&{&1.ref, &1})
  end

  defp apply_default_control(session) do
    if process_only_ssh?(session) do
      session
      |> Map.put(:control_mode, "ignored")
      |> Map.put(:control_project, "")
      |> Map.put(:control_note, "process-only SSH observation; auto-ignored")
    else
      Map.put(session, :control_mode, "uncontrolled")
    end
  end

  defp apply_control(session, control) do
    session
    |> Map.put(:control_mode, control.mode)
    |> Map.put(:control_project, control.project)
    |> Map.put(:control_note, control.note)
  end

  defp process_only_ssh?(session) do
    Map.get(session, :type) in ["process", "ssh"] and
      Map.get(session, :kind) in ["ssh", "sshd"] and
      Map.get(session, :process_role) == "process" and
      not tmux_backed?(session)
  end

  defp tmux_backed?(session) do
    present?(Map.get(session, :server)) and
      present?(Map.get(session, :session)) and
      is_integer(Map.get(session, :window)) and
      is_integer(Map.get(session, :pane))
  end

  defp present?(value), do: value not in [nil, ""]

  defp attrs_from_session(session) do
    %{
      ref: Map.get(session, :ref, ""),
      host: Map.get(session, :host, ""),
      type: Map.get(session, :type, ""),
      kind: Map.get(session, :kind, ""),
      ssh_target: Map.get(session, :ssh_target, ""),
      tmux_server: Map.get(session, :server, ""),
      session_name: Map.get(session, :session, ""),
      window: Map.get(session, :window),
      pane: Map.get(session, :pane),
      pid: Map.get(session, :pid),
      current_path: Map.get(session, :current_path, ""),
      title: Map.get(session, :title, "")
    }
  end

  defp maybe_filter_mode(query, nil), do: query
  defp maybe_filter_mode(query, mode), do: where(query, [control], control.mode == ^mode)
end
