defmodule JX.Notifications.Router do
  @moduledoc """
  Best-effort routing for operator-visible notification events.

  The router redacts and normalizes events before delivering them to configured
  sinks. Sink failures are reported in the routing result and do not mutate
  approval or workspace state.
  """

  alias JX.Notifications.FileSink
  alias JX.Redaction

  @sensitive_key ~r/(token|secret|password|passwd|api[_-]?key|access[_-]?key|private[_-]?key|credential|authorization|auth)/i

  @spec route(map(), keyword()) :: map()
  def route(event, opts \\ []) when is_map(event) do
    route_many([event], opts)
  end

  @spec route_many([map()], keyword()) :: map()
  def route_many(events, opts \\ []) when is_list(events) do
    sinks = Keyword.get_lazy(opts, :sinks, &configured_sinks/0)
    events = Enum.map(events, &normalize/1)

    results =
      for event <- events,
          sink <- sinks do
        deliver(sink, event)
      end

    errors =
      results
      |> Enum.filter(&match?({:error, _reason}, &1))
      |> Enum.map(fn {:error, reason} -> inspect(reason) end)

    %{
      events: length(events),
      sinks: length(sinks),
      delivered: Enum.count(results, &(&1 == :ok)),
      errors: errors
    }
  end

  def configured_sinks do
    :jx
    |> Application.get_env(:notification_sinks, default_sinks())
    |> normalize_sinks()
  end

  def normalize(event) when is_map(event) do
    event
    |> Map.put_new(:routed_at, DateTime.utc_now())
    |> normalize_value()
    |> redact()
  end

  defp default_sinks do
    case System.get_env("JX_NOTIFICATION_FILE") do
      nil -> [JX.Notifications.ConsoleSink]
      "" -> [JX.Notifications.ConsoleSink]
      path -> [JX.Notifications.ConsoleSink, {FileSink, [path: path]}]
    end
  end

  defp normalize_sinks(sinks) when is_list(sinks), do: sinks
  defp normalize_sinks(nil), do: []
  defp normalize_sinks(sink), do: [sink]

  defp deliver({module, opts}, event) when is_atom(module) and is_list(opts) do
    module.deliver(event, opts)
  rescue
    exception -> {:error, {module, exception}}
  catch
    kind, reason -> {:error, {module, kind, reason}}
  end

  defp deliver(module, event) when is_atom(module), do: deliver({module, []}, event)

  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_value(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_value(%Time{} = value), do: Time.to_iso8601(value)
  defp normalize_value(values) when is_list(values), do: Enum.map(values, &normalize_value/1)

  defp normalize_value(%{} = map) do
    Map.new(map, fn {key, value} -> {key, normalize_value(value)} end)
  end

  defp normalize_value(value), do: value

  defp redact(%{} = map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key), do: {key, "<redacted>"}, else: {key, redact(value)}
    end)
  end

  defp redact(values) when is_list(values), do: Enum.map(values, &redact/1)
  defp redact(value) when is_binary(value), do: Redaction.redact_command(value)
  defp redact(value), do: value

  defp sensitive_key?(key), do: Regex.match?(@sensitive_key, to_string(key))
end
