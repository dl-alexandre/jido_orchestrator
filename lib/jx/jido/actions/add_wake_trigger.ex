defmodule JX.Jido.Actions.AddWakeTrigger do
  @moduledoc """
  Register a scheduled wake trigger.
  """

  use Jido.Action,
    name: "jx_add_wake_trigger",
    description: "Create a durable scheduled wake trigger",
    category: "jx",
    tags: ["monitor", "events", "wake", "scheduler", "safe"],
    schema: [
      message: [type: :string, required: true, doc: "Wake message"],
      name: [type: :string, default: "", doc: "Optional trigger label"],
      project: [type: :string, default: "", doc: "Optional project label"],
      ref: [type: :string, default: "", doc: "Optional session or work reference"],
      severity: [
        type: {:in, ["info", "notice", "warning", "critical"]},
        default: "warning",
        doc: "Monitor severity"
      ],
      schedule: [type: {:in, ["once", "every"]}, default: "once", doc: "Schedule mode"],
      next_run_at: [type: :string, default: "", doc: "ISO 8601 run time"],
      delay_seconds: [type: :integer, default: 0, doc: "Delay from now when next_run_at is empty"],
      every_seconds: [type: :integer, default: 0, doc: "Recurring interval for every schedule"]
    ]

  alias JX.Jido.Actions.WorkspaceAction
  alias JX.Workspace

  @impl true
  def run(params, _context) do
    with {:ok, schedule_attrs} <- schedule_attrs(params) do
      WorkspaceAction.call(
        fn ->
          Workspace.add_wake_trigger(
            Map.merge(schedule_attrs, %{
              message: params.message,
              name: params.name,
              project: params.project,
              ref: params.ref,
              severity: params.severity,
              schedule: params.schedule
            })
          )
        end,
        :wake_trigger
      )
    end
  end

  defp schedule_attrs(%{next_run_at: next_run_at} = params)
       when is_binary(next_run_at) and next_run_at != "" do
    case DateTime.from_iso8601(next_run_at) do
      {:ok, run_at, _offset} -> recurring_attrs(params, run_at)
      {:error, _reason} -> {:error, "next_run_at must be ISO 8601 with a timezone"}
    end
  end

  defp schedule_attrs(params) do
    delay_seconds = max(params.delay_seconds || 0, 0)
    recurring_attrs(params, DateTime.add(DateTime.utc_now(), delay_seconds, :second))
  end

  defp recurring_attrs(%{schedule: "every", every_seconds: every_seconds}, run_at)
       when is_integer(every_seconds) and every_seconds > 0 do
    {:ok, %{next_run_at: run_at, every_seconds: every_seconds}}
  end

  defp recurring_attrs(%{schedule: "every"}, _run_at) do
    {:error, "every schedule requires a positive every_seconds"}
  end

  defp recurring_attrs(_params, run_at), do: {:ok, %{next_run_at: run_at, every_seconds: nil}}
end
