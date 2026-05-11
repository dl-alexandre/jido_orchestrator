defmodule JX.GoogleMeet.BrowserAgentRunner do
  @moduledoc """
  Browser-agent adapter for joining Google Meet sessions.

  The adapter keeps the durable `jx` session boundary independent from any
  specific browser-agent runtime. A caller can inject an in-process client for
  tests or provide a command that receives session JSON on stdin and returns a
  JSON result on stdout.
  """

  alias JX.GoogleMeet
  alias JX.GoogleMeet.Session
  alias JX.Shell

  @runner "browser-agent"

  @doc """
  Joins a Meet session through an injected browser agent or configured command.
  """
  def join(%Session{} = session, opts \\ []) do
    cond do
      Keyword.has_key?(opts, :join_client) ->
        invoke_client(Keyword.fetch!(opts, :join_client), session, opts)

      command = browser_agent_command(opts) ->
        run_command(command, session, opts)

      true ->
        {:error,
         "browser agent runner requires --browser-agent-command or JX_MEET_BROWSER_AGENT_CMD; use --runner chrome-cdp for the built-in Chrome/CDP fallback"}
    end
  end

  defp invoke_client(client, session, opts) when is_function(client, 2) do
    client.(session, opts)
  end

  defp invoke_client(client, session, opts) when is_atom(client) do
    client.join(session, opts)
  end

  defp invoke_client(client, _session, _opts) do
    {:error, "unsupported browser agent client #{inspect(client)}"}
  end

  defp run_command(command, session, opts) do
    payload =
      %{
        runner: @runner,
        task: browser_agent_task(session, opts),
        session: GoogleMeet.session_summary(session),
        options: command_options(opts)
      }

    with {:ok, payload_path} <- write_payload(payload) do
      try do
        case System.cmd("sh", ["-lc", "#{command} < #{Shell.quote(payload_path)}"],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            command_result(output, session, command)

          {output, status} ->
            {:error, "browser agent command exited #{status}: #{String.trim(output)}"}
        end
      after
        File.rm(payload_path)
      end
    end
  rescue
    error -> {:error, "browser agent command failed: #{Exception.message(error)}"}
  end

  defp write_payload(payload) do
    path =
      Path.join(
        System.tmp_dir!(),
        "jx-meet-browser-agent-#{System.unique_integer([:positive])}.json"
      )

    case File.write(path, Jason.encode!(payload)) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "could not write browser agent payload: #{inspect(reason)}"}
    end
  end

  defp command_result(output, session, command) do
    output = String.trim(output)

    result =
      case Jason.decode(output) do
        {:ok, decoded} when is_map(decoded) ->
          decoded

        _other ->
          %{
            "status" => "joining",
            "output" => output
          }
      end

    {:ok, normalize_result(result, session, command)}
  end

  defp normalize_result(result, session, command) do
    %{
      runner: Map.get(result, "runner", @runner),
      status: normalize_status(result),
      debug_url: Map.get(result, "debug_url", Map.get(result, "debugUrl", "")),
      target: normalize_target(Map.get(result, "target"), session),
      paired: normalize_paired(Map.get(result, "paired")),
      cdp: %{"mode" => @runner},
      joined?: truthy?(Map.get(result, "joined") || Map.get(result, "joined?")),
      join_clicked?:
        truthy?(
          Map.get(result, "join_clicked") ||
            Map.get(result, "joinClicked") ||
            Map.get(result, "join_clicked?")
        ),
      actions: Map.get(result, "actions", []),
      output: Map.get(result, "output", ""),
      command: command,
      completed_at: DateTime.utc_now()
    }
  end

  defp normalize_status(%{"status" => status}) when status in ["joining", "live"], do: status

  defp normalize_status(result) do
    if truthy?(Map.get(result, "joined") || Map.get(result, "joined?")) do
      "live"
    else
      "joining"
    end
  end

  defp normalize_target(target, _session) when is_map(target), do: stringify_keys(target)

  defp normalize_target(_target, session) do
    %{
      "type" => "browser-agent",
      "url" => session.meeting_uri
    }
  end

  defp normalize_paired(nil), do: nil
  defp normalize_paired(paired) when is_map(paired), do: stringify_keys(paired)
  defp normalize_paired(_paired), do: nil

  defp browser_agent_task(session, opts) do
    %{
      intent: "join_google_meet",
      meeting_uri: session.meeting_uri,
      meeting_code: session.meeting_code,
      participant_identity: "signed-in browser profile",
      controls: %{
        mute: Keyword.get(opts, :mute, true),
        camera_off: Keyword.get(opts, :camera_off, true),
        click_join: Keyword.get(opts, :click_join, true),
        paired_click_join: Keyword.get(opts, :paired_click_join, false)
      }
    }
  end

  defp command_options(opts) do
    %{
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000),
      settle_ms: Keyword.get(opts, :settle_ms, 2_000),
      poll_ms: Keyword.get(opts, :poll_ms, 1_000)
    }
  end

  defp browser_agent_command(opts) do
    first_present([
      Keyword.get(opts, :browser_agent_command),
      System.get_env("JX_MEET_BROWSER_AGENT_CMD")
    ])
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp first_present(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end)
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false
end
