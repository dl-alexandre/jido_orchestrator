defmodule JX.OrchestratorQueueDecisions do
  @moduledoc """
  Converts monitor queue items into safe orchestration decisions.

  Queue-backed decisions are intentionally conservative. They only promote queue
  work that already has an executable, read-only handler in the orchestrator.
  """

  def build(queues, profiles, events, opts \\ []) do
    if Keyword.get(opts, :include_current, true) do
      profiles_by_ref = profiles_by_ref(profiles)
      events_by_ref = events_by_ref(events)

      queues
      |> queue_items("observe")
      |> Enum.flat_map(&observe_decision(&1, profiles_by_ref, events_by_ref))
      |> Enum.uniq_by(&{&1.ref, &1.action})
    else
      []
    end
  end

  defp observe_decision(item, profiles_by_ref, events_by_ref) do
    ref = field(item, :ref)
    profile = Map.get(profiles_by_ref, ref)

    cond do
      ref == "" ->
        []

      is_nil(profile) ->
        []

      suppressed?(profile) ->
        []

      true ->
        events = Map.get(events_by_ref, ref, [])
        reason = first_present([field(item, :reason), "observe queue item"])

        [
          %{
            id: decision_id(profile, "queue-observe", reason),
            action: "observe",
            source: "queue",
            queue_action: "observe",
            safety: "inspect",
            status: "planned",
            ref: ref,
            state: deep(profile, [:comparison, :state]),
            prompt_status: deep(profile, [:next_prompt, :status]),
            message: "",
            directive_sent_at: deep(profile, [:actual, :last_directive, :sent_at]),
            directive_message:
              first_present([
                deep(profile, [:next_prompt, :text]),
                deep(profile, [:actual, :last_directive, :message])
              ]),
            reason: reason,
            event_ids: event_ids(events)
          }
        ]
    end
  end

  defp profiles_by_ref(profiles) do
    Enum.reduce(profiles, %{}, fn profile, acc ->
      case field(profile, :ref) do
        "" -> acc
        ref -> Map.put(acc, ref, profile)
      end
    end)
  end

  defp events_by_ref(events) do
    events
    |> Enum.reduce(%{}, fn event, acc ->
      case field(event, :ref) do
        "" -> acc
        ref -> Map.update(acc, ref, [event], &[event | &1])
      end
    end)
    |> Map.new(fn {ref, ref_events} -> {ref, Enum.reverse(ref_events)} end)
  end

  defp queue_items(queues, action) do
    queues
    |> Enum.find(%{}, &(field(&1, :action) == action))
    |> field(:items, [])
    |> List.wrap()
  end

  defp suppressed?(profile) do
    deep(profile, [:session, :control_mode]) in ["ignored", "protected"]
  end

  defp event_ids(events) do
    events
    |> Enum.map(&field(&1, :id))
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp decision_id(profile, action, reason) do
    source = [
      field(profile, :ref),
      action,
      deep(profile, [:comparison, :state]),
      deep(profile, [:next_prompt, :status]),
      reason
    ]

    hash =
      :crypto.hash(:sha256, Enum.intersperse(Enum.map(source, &stringify/1), <<0>>))
      |> Base.encode16(case: :lower)

    "orc-" <> binary_part(hash, 0, 10)
  end

  defp deep(value, []), do: value

  defp deep(%{} = map, [key | rest]) do
    map
    |> field(key, nil)
    |> deep(rest)
  end

  defp deep(_value, _path), do: nil

  defp field(value, key, default \\ "")

  defp field(%{} = map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key), default)
    end
  end

  defp field(_value, _key, default), do: default

  defp first_present(values) do
    Enum.find_value(values, "", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end)
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(nil), do: ""
  defp stringify(value), do: to_string(value)
end
