defmodule JX.GoogleMeet.ChromeRunner do
  @moduledoc """
  Chrome/CDP automation for joining Google Meet sessions.
  """

  alias JX.ChromeDevTools
  alias JX.GoogleMeet
  alias JX.GoogleMeet.Session
  alias JX.Shell

  @default_debug_url "http://127.0.0.1:9222"
  @default_timeout_ms 30_000

  @doc """
  Opens or recovers a Meet tab, drives the pre-join UI, and returns observed state.
  """
  def join(%Session{} = session, opts \\ []) do
    case Keyword.get(opts, :join_client) do
      nil -> run_join(session, opts)
      join_client -> join_client.(session, opts)
    end
  end

  defp run_join(session, opts) do
    debug_url =
      Keyword.get(opts, :debug_url) || blank_default(session.chrome_node, @default_debug_url)

    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    with :ok <- maybe_launch_chrome(debug_url, session, opts),
         {:ok, target} <- find_or_open_target(debug_url, session.meeting_uri, opts),
         {:ok, cdp_result} <-
           drive_target(target, session, Keyword.put(opts, :timeout_ms, timeout_ms)),
         {:ok, paired_result} <- maybe_drive_paired(session, opts) do
      {:ok,
       %{
         runner: "chrome-cdp",
         status: status_for_result(cdp_result),
         debug_url: debug_url,
         target: target,
         cdp: cdp_result,
         paired: paired_result,
         joined?: Map.get(cdp_result, :in_call, false),
         join_clicked?: Map.get(cdp_result, :join_clicked, false),
         actions: Map.get(cdp_result, :actions, []),
         completed_at: DateTime.utc_now()
       }}
    end
  end

  defp maybe_launch_chrome(_debug_url, _session, opts) do
    if Keyword.get(opts, :launch, false) do
      launch_chrome(opts)
    else
      :ok
    end
  end

  defp launch_chrome(opts) do
    chrome_bin = Keyword.get(opts, :chrome_bin) || chrome_binary()
    profile_dir = Keyword.get(opts, :profile_dir) || default_profile_dir()
    port = debug_port(Keyword.get(opts, :debug_url) || @default_debug_url)

    args = [
      "--remote-debugging-port=#{port}",
      "--user-data-dir=#{profile_dir}",
      "--no-first-run",
      "--no-default-browser-check",
      "about:blank"
    ]

    command =
      ([Shell.quote(chrome_bin)] ++ Enum.map(args, &Shell.quote/1))
      |> Enum.join(" ")

    {_output, 0} = System.cmd("sh", ["-lc", "#{command} >/dev/null 2>&1 &"])
    wait_for_chrome(Keyword.get(opts, :debug_url) || @default_debug_url, opts)
  rescue
    error -> {:error, "failed to launch Chrome: #{Exception.message(error)}"}
  end

  defp wait_for_chrome(debug_url, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :launch_timeout_ms, 10_000)
    wait_for_chrome(debug_url, opts, deadline)
  end

  defp wait_for_chrome(debug_url, opts, deadline) do
    case ChromeDevTools.list_targets(debug_url, opts) do
      {:ok, _targets} ->
        :ok

      {:error, reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, reason}
        else
          Process.sleep(200)
          wait_for_chrome(debug_url, opts, deadline)
        end
    end
  end

  defp find_or_open_target(debug_url, meeting_uri, opts) do
    with {:ok, targets} <- ChromeDevTools.list_targets(debug_url, opts) do
      case Enum.find(targets, &meet_target?(&1, meeting_uri)) do
        nil -> open_target(debug_url, meeting_uri, opts)
        target -> {:ok, stringify_keys(target)}
      end
    end
  end

  defp open_target(debug_url, meeting_uri, opts) do
    case ChromeDevTools.open_target(debug_url, meeting_uri, opts) do
      {:ok, %{"webSocketDebuggerUrl" => _url} = target} ->
        {:ok, stringify_keys(target)}

      {:ok, _target} ->
        with {:ok, targets} <- ChromeDevTools.list_targets(debug_url, opts),
             target when not is_nil(target) <- Enum.find(targets, &meet_target?(&1, meeting_uri)) do
          {:ok, stringify_keys(target)}
        else
          nil -> {:error, "opened Meet tab but Chrome did not return a debuggable target"}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp meet_target?(target, meeting_uri) do
    target_url = Map.get(target, "url") || Map.get(target, :url) || ""

    with {:ok, expected} <- GoogleMeet.normalize_meeting(meeting_uri),
         {:ok, actual} <- GoogleMeet.normalize_meeting(target_url) do
      expected.meeting_code == actual.meeting_code
    else
      _other -> false
    end
  end

  defp drive_target(%{"webSocketDebuggerUrl" => websocket_url}, session, opts) do
    cdp = Keyword.get(opts, :cdp_client, ChromeDevTools)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    cdp.with_session(websocket_url, fn conn ->
      with {:ok, _result, conn} <- cdp.command(conn, "Page.enable", %{}, timeout_ms: timeout_ms),
           {:ok, _result, conn} <-
             cdp.command(conn, "Runtime.enable", %{}, timeout_ms: timeout_ms),
           {:ok, _result, conn} <-
             cdp.command(conn, "Page.navigate", %{url: session.meeting_uri},
               timeout_ms: timeout_ms
             ) do
        Process.sleep(Keyword.get(opts, :settle_ms, 2_000))
        drive_join_loop(cdp, conn, session, opts)
      end
    end)
  end

  defp drive_target(_target, _session, _opts) do
    {:error, "Chrome target has no webSocketDebuggerUrl"}
  end

  defp drive_join_loop(cdp, conn, session, opts) do
    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    drive_join_loop(cdp, conn, session, opts, deadline, [])
  end

  defp drive_join_loop(cdp, conn, session, opts, deadline, attempts) do
    expression = join_expression(opts)

    with {:ok, result, conn} <-
           cdp.command(
             conn,
             "Runtime.evaluate",
             %{
               expression: expression,
               returnByValue: true,
               awaitPromise: false
             },
             timeout_ms: min(Keyword.get(opts, :timeout_ms, @default_timeout_ms), 5_000)
           ) do
      value = get_in(result, ["result", "value"]) || %{}
      attempt = normalize_attempt(value)
      attempts = attempts ++ [attempt]

      cond do
        attempt.in_call ->
          {:ok, finish_result(session, attempts, "live")}

        not Keyword.get(opts, :click_join, true) ->
          {:ok, finish_result(session, attempts, "joining")}

        attempt.join_clicked and Keyword.get(opts, :stop_after_click, true) ->
          {:ok, finish_result(session, attempts, "joining")}

        System.monotonic_time(:millisecond) >= deadline ->
          {:ok, finish_result(session, attempts, "joining")}

        true ->
          Process.sleep(Keyword.get(opts, :poll_ms, 1_000))
          drive_join_loop(cdp, conn, session, opts, deadline, attempts)
      end
    end
  end

  defp finish_result(_session, attempts, status) do
    last = List.last(attempts) || %{}

    %{
      status: status,
      in_call: Map.get(last, :in_call, false),
      join_clicked: Enum.any?(attempts, &Map.get(&1, :join_clicked, false)),
      actions: Enum.flat_map(attempts, &Map.get(&1, :actions, [])),
      attempts: attempts,
      last: last
    }
  end

  defp normalize_attempt(value) when is_map(value) do
    %{
      in_call: truthy?(Map.get(value, "in_call") || Map.get(value, :in_call)),
      join_clicked: truthy?(Map.get(value, "join_clicked") || Map.get(value, :join_clicked)),
      actions: Map.get(value, "actions") || Map.get(value, :actions) || [],
      url: Map.get(value, "url") || Map.get(value, :url) || "",
      title: Map.get(value, "title") || Map.get(value, :title) || "",
      body_sample: Map.get(value, "body_sample") || Map.get(value, :body_sample) || ""
    }
  end

  defp normalize_attempt(_value), do: %{in_call: false, join_clicked: false, actions: []}

  defp maybe_drive_paired(%Session{paired_chrome_node: paired_node} = session, opts)
       when paired_node not in [nil, ""] do
    if Keyword.get(opts, :paired, true) do
      paired_opts =
        opts
        |> Keyword.put(:debug_url, paired_node)
        |> Keyword.put(:click_join, Keyword.get(opts, :paired_click_join, false))
        |> Keyword.put(:profile_dir, paired_profile_dir(opts))

      with :ok <- maybe_launch_chrome(paired_node, session, paired_opts),
           {:ok, target} <- find_or_open_target(paired_node, session.meeting_uri, paired_opts),
           {:ok, cdp_result} <- drive_target(target, session, paired_opts) do
        {:ok,
         %{
           runner: "chrome-cdp",
           status: status_for_result(cdp_result),
           debug_url: paired_node,
           target: target,
           cdp: cdp_result,
           joined?: Map.get(cdp_result, :in_call, false),
           join_clicked?: Map.get(cdp_result, :join_clicked, false),
           actions: Map.get(cdp_result, :actions, []),
           completed_at: DateTime.utc_now()
         }}
      end
    else
      {:ok, nil}
    end
  end

  defp maybe_drive_paired(_session, _opts), do: {:ok, nil}

  defp join_expression(opts) do
    mute? = Keyword.get(opts, :mute, true)
    camera_off? = Keyword.get(opts, :camera_off, true)
    click_join? = Keyword.get(opts, :click_join, true)

    """
    (() => {
      const normalize = value => (value || '').toString().toLowerCase().replace(/\\s+/g, ' ').trim();
      const visible = element => {
        if (!element) return false;
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.visibility !== 'hidden' && style.display !== 'none' && rect.width > 0 && rect.height > 0;
      };
      const labelFor = element => normalize([
        element.getAttribute('aria-label'),
        element.getAttribute('data-tooltip'),
        element.getAttribute('title'),
        element.innerText,
        element.textContent
      ].filter(Boolean).join(' '));
      const controls = Array.from(document.querySelectorAll('button,[role="button"],a')).filter(visible);
      const actions = [];
      const clickFirst = (name, predicate) => {
        const match = controls.find(element => predicate(labelFor(element), element));
        if (!match) return false;
        match.click();
        actions.push({name, label: labelFor(match)});
        return true;
      };

      if (#{inspect(mute?)}) {
        clickFirst('mute_microphone', label =>
          label.includes('turn off microphone') ||
          label.includes('mute microphone') ||
          (label.includes('microphone') && label.includes('turn off'))
        );
      }

      if (#{inspect(camera_off?)}) {
        clickFirst('turn_off_camera', label =>
          label.includes('turn off camera') ||
          label.includes('turn off video') ||
          (label.includes('camera') && label.includes('turn off'))
        );
      }

      clickFirst('dismiss_prompt', label =>
        label.includes('got it') ||
        label.includes('dismiss') ||
        label.includes('continue without microphone') ||
        label.includes('continue without camera')
      );

      const inCall = controls.some(element => {
        const label = labelFor(element);
        return label.includes('leave call') || label.includes('leave meeting');
      });

      let joinClicked = false;
      if (#{inspect(click_join?)} && !inCall) {
        joinClicked = clickFirst('join_meet', label =>
          label.includes('join now') ||
          label.includes('ask to join') ||
          label.includes('join meeting') ||
          label === 'join'
        );
      }

      const bodyText = normalize(document.body ? document.body.innerText : '').slice(0, 1000);

      return {
        in_call: inCall,
        join_clicked: joinClicked,
        actions,
        url: window.location.href,
        title: document.title,
        body_sample: bodyText
      };
    })()
    """
  end

  defp status_for_result(%{status: status}) when status in ["joining", "live"], do: status
  defp status_for_result(%{"status" => status}) when status in ["joining", "live"], do: status
  defp status_for_result(%{joined?: true}), do: "live"
  defp status_for_result(%{"joined?" => true}), do: "live"
  defp status_for_result(%{join_clicked?: true}), do: "joining"
  defp status_for_result(%{"join_clicked?" => true}), do: "joining"
  defp status_for_result(_result), do: "joining"

  defp chrome_binary do
    System.get_env("JX_CHROME_BIN") ||
      platform_chrome_binary()
  end

  defp platform_chrome_binary do
    case :os.type() do
      {:unix, :darwin} -> "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
      _other -> "google-chrome"
    end
  end

  defp default_profile_dir do
    Path.expand("~/.jx/chrome/google-meet")
  end

  defp paired_profile_dir(opts) do
    Keyword.get(opts, :paired_profile_dir) || Path.join(default_profile_dir(), "paired")
  end

  defp debug_port(debug_url) do
    case URI.parse(debug_url) do
      %URI{port: port} when is_integer(port) -> port
      _other -> 9222
    end
  end

  defp blank_default(value, default) when value in [nil, ""], do: default
  defp blank_default(value, _default), do: value

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
