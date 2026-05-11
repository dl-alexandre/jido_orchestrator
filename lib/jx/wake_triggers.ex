defmodule JX.WakeTriggers do
  @moduledoc """
  Durable wake trigger storage for scheduled external attention requests.
  """

  import Ecto.Query

  alias JX.Repo
  alias JX.WakeTriggers.WakeTrigger

  @trigger_prefix "wtr-"

  def statuses, do: WakeTrigger.statuses()
  def schedules, do: WakeTrigger.schedules()

  def add(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:trigger_id, trigger_id())
      |> Map.put_new(:status, "active")
      |> Map.put_new(:schedule, "once")
      |> Map.put_new(:severity, "warning")

    %WakeTrigger{}
    |> WakeTrigger.changeset(attrs)
    |> Repo.insert()
  end

  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    WakeTrigger
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_project(Keyword.get(opts, :project))
    |> maybe_filter_ref(Keyword.get(opts, :ref))
    |> order_by([trigger], asc: trigger.next_run_at, desc: trigger.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def get(trigger_id), do: Repo.get_by(WakeTrigger, trigger_id: trigger_id)

  def cancel(trigger_id) do
    update_status(trigger_id, "cancelled", "cancelled by operator")
  end

  def disable(trigger_id) do
    update_status(trigger_id, "disabled", "disabled by operator")
  end

  def list_due(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 20)

    WakeTrigger
    |> where([trigger], trigger.status == "active")
    |> where([trigger], not is_nil(trigger.next_run_at))
    |> where([trigger], trigger.next_run_at <= ^now)
    |> order_by([trigger], asc: trigger.next_run_at, asc: trigger.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def mark_run(%WakeTrigger{} = trigger, attrs \\ []) do
    attrs = Map.new(attrs)
    now = Map.get(attrs, :now, DateTime.utc_now())
    result = Map.get(attrs, :result, "wake emitted")

    trigger
    |> WakeTrigger.changeset(mark_run_attrs(trigger, now, result))
    |> Repo.update()
  end

  defp mark_run_attrs(
         %WakeTrigger{schedule: "every", every_seconds: every_seconds, run_count: run_count},
         now,
         result
       )
       when is_integer(every_seconds) and every_seconds > 0 do
    %{
      status: "active",
      next_run_at: DateTime.add(now, every_seconds, :second),
      last_run_at: now,
      run_count: increment_run_count(run_count),
      last_result: result
    }
  end

  defp mark_run_attrs(%WakeTrigger{run_count: run_count}, now, result) do
    %{
      status: "completed",
      next_run_at: nil,
      last_run_at: now,
      run_count: increment_run_count(run_count),
      last_result: result
    }
  end

  defp increment_run_count(nil), do: 1
  defp increment_run_count(count), do: count + 1

  defp update_status(trigger_id, status, result) do
    case get(trigger_id) do
      nil ->
        {:error, :wake_trigger_not_found}

      trigger ->
        trigger
        |> WakeTrigger.changeset(%{
          status: status,
          next_run_at: nil,
          last_result: result
        })
        |> Repo.update()
    end
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [trigger], trigger.status == ^status)

  defp maybe_filter_project(query, nil), do: query

  defp maybe_filter_project(query, project),
    do: where(query, [trigger], trigger.project == ^project)

  defp maybe_filter_ref(query, nil), do: query
  defp maybe_filter_ref(query, ref), do: where(query, [trigger], trigger.ref == ^ref)

  defp trigger_id do
    random =
      5
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    @trigger_prefix <> random
  end
end
