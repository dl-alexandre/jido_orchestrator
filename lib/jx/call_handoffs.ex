defmodule JX.CallHandoffs do
  @moduledoc """
  Persistence for call and meeting handoffs.

  A handoff is the durable note left by a realtime surface: what the operator
  said, which decisions were made, and what follow-up work should stay visible
  to the orchestrator.
  """

  import Ecto.Query

  alias JX.CallHandoffs.CallHandoff
  alias JX.Notifications
  alias JX.Repo

  @handoff_prefix "cal-"

  def statuses, do: CallHandoff.statuses()
  def surfaces, do: CallHandoff.surfaces()

  def create(attrs, opts \\ []) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:handoff_id, handoff_id())
      |> Map.put_new(:surface, "call")
      |> Map.put_new(:status, "open")
      |> encode_json_field(:decisions, [])
      |> encode_json_field(:follow_ups, [])
      |> encode_json_field(:brief_snapshot, Keyword.get(opts, :brief_snapshot, %{}))
      |> encode_json_field(:payload, %{})

    %CallHandoff{}
    |> CallHandoff.changeset(attrs)
    |> Repo.insert()
  end

  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    CallHandoff
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_surface(Keyword.get(opts, :surface))
    |> maybe_filter_project(Keyword.get(opts, :project))
    |> maybe_filter_ref(Keyword.get(opts, :ref))
    |> order_by([handoff], desc: handoff.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def get(handoff_id), do: Repo.get_by(CallHandoff, handoff_id: handoff_id)

  def close(handoff_id, summary \\ "") do
    update_terminal(handoff_id, "closed", summary)
  end

  def apply(handoff_id, summary \\ "") do
    update_terminal(handoff_id, "applied", summary)
  end

  def summary(opts \\ []) do
    handoffs = list(Keyword.put_new(opts, :limit, 500))

    %{
      total: length(handoffs),
      open_total: Enum.count(handoffs, &(&1.status == "open")),
      by_status: count_by(handoffs, & &1.status),
      by_surface: count_by(handoffs, & &1.surface),
      by_project: count_by(handoffs, & &1.project),
      latest:
        handoffs
        |> Enum.take(Keyword.get(opts, :latest, 5))
        |> Enum.map(&handoff_summary/1)
    }
  end

  def handoff_summary(%CallHandoff{} = handoff) do
    %{
      handoff_id: handoff.handoff_id,
      surface: handoff.surface,
      status: handoff.status,
      project: handoff.project,
      ref: handoff.ref,
      title: handoff.title,
      summary: handoff.summary,
      operator_input: handoff.operator_input,
      decisions: decode_json_list(handoff.decisions),
      follow_ups: decode_json_list(handoff.follow_ups),
      closed_at: handoff.closed_at,
      updated_at: handoff.updated_at,
      inserted_at: handoff.inserted_at
    }
  end

  defp update_terminal(handoff_id, status, summary) do
    case get(handoff_id) do
      nil ->
        {:error, :call_handoff_not_found}

      handoff ->
        merged_summary =
          [handoff.summary, summary]
          |> Enum.reject(&blank?/1)
          |> Enum.join("\n")

        result =
          handoff
          |> CallHandoff.changeset(%{
            status: status,
            summary: merged_summary,
            closed_at: DateTime.utc_now()
          })
          |> Repo.update()

        case result do
          {:ok, updated} ->
            _ack = Notifications.acknowledge_all(ref: updated.handoff_id)
            {:ok, updated}

          other ->
            other
        end
    end
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [handoff], handoff.status == ^status)

  defp maybe_filter_surface(query, nil), do: query

  defp maybe_filter_surface(query, surface),
    do: where(query, [handoff], handoff.surface == ^surface)

  defp maybe_filter_project(query, nil), do: query

  defp maybe_filter_project(query, project),
    do: where(query, [handoff], handoff.project == ^project)

  defp maybe_filter_ref(query, nil), do: query
  defp maybe_filter_ref(query, ref), do: where(query, [handoff], handoff.ref == ^ref)

  defp encode_json_field(attrs, key, default) do
    Map.update(attrs, key, encode_json(default), &encode_json/1)
  end

  defp encode_json(value) when is_binary(value), do: value
  defp encode_json(value), do: Jason.encode!(value)

  defp decode_json_list(value) do
    case Jason.decode(value || "[]") do
      {:ok, list} when is_list(list) -> list
      _other -> []
    end
  end

  defp count_by(items, fun) do
    items
    |> Enum.map(fun)
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp handoff_id do
    @handoff_prefix <>
      (5
       |> :crypto.strong_rand_bytes()
       |> Base.encode16(case: :lower))
  end
end
