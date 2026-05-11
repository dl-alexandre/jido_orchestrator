defmodule JX.SessionStatus do
  @moduledoc """
  Extracts a compact work status from captured agent/tmux pane text.

  ## Vendor coupling

  Several pattern groups below are tied to the terminal UI of specific
  external coding-agent CLIs (Claude Code, opencode, codex). When a
  vendor ships a UI string change these patterns must change with it,
  or work-state classification will silently degrade to `unknown`.

  See `JX.SessionStatus.Vendors` for:

    * the last-verified version per vendor
    * a fixture corpus of representative scrollback samples

  The fixtures are exercised by
  `test/jx/session_status/vendors_test.exs` so silent UI drift
  becomes a loud test failure.
  """

  @work_states ~w(unobservable unknown blocked running waiting idle)
  @recent_line_count 20

  # General error/blocked signals. Vendor-agnostic.
  @blocked_patterns [
    ~r/\berror:\s+/i,
    ~r/exit code [1-9]\d*/i,
    ~r/process completed with exit code [1-9]\d*/i,
    ~r/failed to push/i,
    ~r/updates were rejected/i,
    ~r/permission denied/i,
    ~r/authentication failed/i
  ]

  # Active-work signals. Mix of generic verbs and Claude Code spinner
  # phrasings ("tempering"), Claude background-shell/monitor counters,
  # and the opencode "Thinking:" prose prefix.
  # Vendor-coupled — see JX.SessionStatus.Vendors.
  @running_patterns [
    ~r/working/i,
    ~r/thinking:/i,
    ~r/tempering/i,
    ~r/background terminal running/i,
    ~r/running in the background/i,
    ~r/\b\d+\s+shells?\s+still running\b/i,
    ~r/\b\d+\s+shells?\b/i,
    ~r/\b\d+\s+monitors?\s+still running\b/i,
    ~r/\b\d+\s+monitors?\b/i
  ]

  # Claude Code action-verb spinner lines like "⏺ Reading…" or "✳ Writing…".
  # Vendor-coupled (Claude Code).
  @active_agent_line_patterns [
    ~r/^\s*[✻✳✽✶✢⏺*]+\s*(thinking|working|writing|searching|reading|running|editing|checking|fixing|investigating|analyzing|compiling|testing)/imu
  ]

  # Weak running hints — "esc interrupt" / "esc to interrupt" footers from
  # opencode and Claude Code. Treated as running only when no idle footer
  # is also present (see weak_running?/1 / agent_idle_footer?/1).
  # Vendor-coupled.
  @weak_running_patterns [
    ~r/esc\s+interrupt/i,
    ~r/esc to interrupt/i
  ]

  # Mostly generic NLU phrasings the agent uses when handing back to the
  # operator. The numbered "1. Yes" line and "do you want to proceed?" are
  # Claude approval-menu specific. Vendor-coupled (partial).
  @waiting_patterns [
    ~r/i'?ll wait/i,
    ~r/would you like me to/i,
    ~r/do you want to proceed\?/i,
    ~r/^\s*1\.\s+Yes\b/im,
    ~r/let me know/i,
    ~r/when you're ready/i,
    ~r/waiting for/i
  ]

  # Claude Code approval-menu UI. Vendor-coupled.
  @approval_prompt_patterns [
    ~r/this command requires approval/i,
    ~r/do you want to proceed\?/i,
    ~r/^\s*❯\s*1\.\s+Yes\b/im,
    ~r/^\s*1\.\s+Yes\b/im,
    ~r/^\s*2\.\s+Yes,\s+and don[’']t ask again/im,
    ~r/^\s*3\.\s+No\b/im
  ]

  # Claude/opencode pasted-text composer marker. Vendor-coupled.
  @staged_prompt_patterns [
    ~r/^\s*[❯>]\s+\[Pasted text #\d+\]/imu
  ]

  # Idle footer signals. Mix of Claude ("accept edits", "bypass permissions"),
  # opencode ("ctrl+p commands"), and the generic shell prompt (`❯` / `>`).
  # Vendor-coupled (partial).
  @idle_patterns [
    ~r/accept edits on/i,
    ~r/ctrl\+p commands/i,
    ~r/[❯>]$/,
    ~r/bypass permissions on/i
  ]

  # Strong idle markers. All three are agent-CLI footers. Vendor-coupled.
  @strong_idle_patterns [
    ~r/accept edits on/i,
    ~r/bypass permissions on/i,
    ~r/ctrl\+p commands/i
  ]

  # Idle footers from agent CLIs. Vendor-coupled (Claude Code).
  @agent_idle_footer_patterns [
    ~r/accept edits on/i,
    ~r/bypass permissions on/i
  ]

  # Neutral chrome lines that classify a session as idle when no stronger
  # signal is present. Mix of Claude composer hints, codex weekly usage
  # ("\d+h \d+% ... weekly"), generic shell prompt. Vendor-coupled (partial).
  @neutral_footer_patterns [
    ~r/tab to queue message/i,
    ~r/tab to amend/i,
    ~r/esc to cancel/i,
    ~r/ctrl\+e to explain/i,
    ~r/context left/i,
    ~r/\d+h\s+\d+%.*weekly/i,
    ~r/↓ to manage/i,
    ~r/[❯>]$/
  ]

  # Lines treated as UI chrome (not real agent answer content). Each
  # entry is grouped roughly by source:
  #   - vendor banner ("claude code v...", "opencode v...", "codex v...")
  #   - shell prompt
  #   - pasted-text composer
  #   - Claude accept/bypass footer
  #   - Claude composer hints / queue/amend/cancel/explain/↓-to-manage
  #   - "esc interrupt" + codex "weekly" footer
  #   - Claude spinner verbs (tempering/caramelizing/thinking/working)
  #   - opencode usage line ("71.7K (27%) · $1.36")
  #   - codex weekly line ("5h 94%")
  #   - generic borders / dividers
  # Vendor-coupled. See JX.SessionStatus.Vendors.
  @chrome_line_patterns [
    ~r/^\s*(claude code|opencode|codex)(\s+v?\d|\b)/i,
    ~r/^\s*[❯>]\s*$/u,
    ~r/^\s*[❯>]\s+\[Pasted text #\d+\]/iu,
    ~r/^\s*[⏵>›❯]+\s*(accept edits on|bypass permissions on)/iu,
    ~r/(accept edits on|bypass permissions on|ctrl\+p commands|ctrl\+t to hide tasks)/i,
    ~r/(tab to queue message|tab to amend|esc to cancel|ctrl\+e to explain|↓ to manage)/i,
    ~r/(esc\s+interrupt|esc to interrupt|context left|\bweekly\b)/i,
    ~r/^\s*[✻✳✽✶*]+\s*(tempering|caramelizing|thinking|working)/iu,
    ~r/^\s*\d+(?:\.\d+)?[KM]?\s+\(\d+%\)\s+·\s+\$\d+/i,
    ~r/^\s*\d+h\s+\d+%/i,
    ~r/^[\s─━═╭╮╰╯│┃┌┐└┘├┤┬┴┼╎╏┆┇·•-]+$/u
  ]

  def work_states, do: @work_states

  def analyze(session, capture) do
    status = Map.get(capture, :status)
    output = Map.get(capture, :output, "")
    summary_text = summary(output, 1_000)
    recent_text = recent_output(output)
    context_text = searchable_text(session, recent_text)

    cond do
      status == "skipped" ->
        result("unobservable", ["no_tmux_pane"])

      status == "error" ->
        result("unknown", ["capture_error"])

      has_match?(summary_text, @blocked_patterns) ->
        result("blocked", matching_signals(summary_text, blocked: @blocked_patterns))

      has_match?(summary_text, @running_patterns) ->
        result("running", matching_signals(summary_text, running: @running_patterns))

      has_match?(summary_text, @waiting_patterns) ->
        result("waiting", matching_signals(summary_text, waiting: @waiting_patterns))

      has_match?(recent_text, @active_agent_line_patterns) ->
        result("running", matching_signals(recent_text, running: @active_agent_line_patterns))

      weak_running?(summary_text) ->
        result("running", matching_signals(summary_text, running: @weak_running_patterns))

      has_match?(summary_text, @strong_idle_patterns) ->
        result("idle", matching_signals(summary_text, idle: @strong_idle_patterns))

      has_match?(recent_text, @running_patterns) ->
        result("running", matching_signals(recent_text, running: @running_patterns))

      has_match?(recent_text, @waiting_patterns) ->
        result("waiting", matching_signals(recent_text, waiting: @waiting_patterns))

      has_match?(summary_text, @neutral_footer_patterns) ->
        result("idle", matching_signals(summary_text, idle: @neutral_footer_patterns))

      has_match?(recent_text, @blocked_patterns) ->
        result("blocked", matching_signals(recent_text, blocked: @blocked_patterns))

      has_match?(context_text, @idle_patterns) ->
        result("idle", matching_signals(context_text, idle: @idle_patterns))

      true ->
        result("unknown", [])
    end
  end

  def summary(output, max_length \\ 500) do
    output
    |> compact_lines()
    |> List.last("")
    |> String.replace(~r/\s+/, " ")
    |> truncate(max_length)
  end

  def meaningful_response?(output) when is_binary(output) do
    output
    |> compact_lines()
    |> Enum.reject(&chrome_line?/1)
    |> Enum.any?()
  end

  def meaningful_response?(_output), do: false

  def active_work?(output) when is_binary(output) do
    summary_text = summary(output, 1_000)
    recent_text = recent_output(output)

    has_match?(summary_text, @running_patterns) or
      has_match?(recent_text, @active_agent_line_patterns) or
      weak_running?(summary_text) or
      has_match?(recent_text, @running_patterns)
  end

  def active_work?(_output), do: false

  def interrupt_hint?(output) when is_binary(output) do
    summary_text = summary(output, 1_000)
    recent_text = recent_output(output)

    weak_running?(summary_text) or
      (has_match?(recent_text, @weak_running_patterns) and not agent_idle_footer?(recent_text))
  end

  def interrupt_hint?(_output), do: false

  def approval_prompt?(output) when is_binary(output) do
    has_match?(output, @approval_prompt_patterns)
  end

  def approval_prompt?(_output), do: false

  def staged_prompt?(output) when is_binary(output) do
    has_match?(output, @staged_prompt_patterns)
  end

  def staged_prompt?(_output), do: false

  def meaningful_response_after?(output, marker) when is_binary(output) and is_binary(marker) do
    marker = String.trim(marker)

    if marker == "" do
      meaningful_response?(output)
    else
      case response_after_marker(output, marker) do
        {:ok, output_after_marker} ->
          meaningful_response?(output_after_marker)

        :not_found ->
          false
      end
    end
  end

  def meaningful_response_after?(output, _marker), do: meaningful_response?(output)

  def final_response?(output) when is_binary(output) do
    output
    |> agent_authored_lines()
    |> Enum.any?()
  end

  def final_response?(_output), do: false

  def final_response_after?(output, marker) when is_binary(output) and is_binary(marker) do
    marker = String.trim(marker)

    if marker == "" do
      final_response?(output)
    else
      case response_after_marker(output, marker) do
        {:ok, output_after_marker} -> final_response?(output_after_marker)
        :not_found -> false
      end
    end
  end

  def final_response_after?(output, _marker), do: final_response?(output)

  def response_after_marker(output, marker) when is_binary(output) and is_binary(marker) do
    marker = String.trim(marker)

    if marker == "" do
      {:ok, output}
    else
      case output_after_last_marker(output, marker) do
        {:ok, output_after_marker} -> {:ok, output_after_marker}
        :not_found -> flexible_output_after_last_marker(output, marker)
      end
    end
  end

  def response_after_marker(_output, _marker), do: :not_found

  defp recent_output(output) do
    output
    |> compact_lines()
    |> Enum.take(-@recent_line_count)
    |> Enum.join("\n")
  end

  defp compact_lines(output) do
    output
    |> String.replace(~r{\e\[[0-9;?]*[ -/]*[@-~]}, "")
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp agent_authored_lines(output) do
    output
    |> String.replace(~r{\e\[[0-9;?]*[ -/]*[@-~]}, "")
    |> String.split("\n", trim: false)
    |> Enum.reduce({[], false}, &collect_agent_authored_line/2)
    |> elem(0)
    |> Enum.reverse()
  end

  defp collect_agent_authored_line(raw_line, {lines, in_tool_block?}) do
    trimmed = String.trim(raw_line)

    cond do
      trimmed == "" ->
        {lines, false}

      tool_invocation_line?(trimmed) ->
        {lines, true}

      tool_result_line?(trimmed) ->
        {lines, true}

      in_tool_block? and tool_output_continuation?(raw_line, trimmed) ->
        {lines, true}

      chrome_line?(trimmed) ->
        {lines, false}

      approval_ui_line?(trimmed) ->
        {lines, false}

      true ->
        {[trimmed | lines], false}
    end
  end

  defp chrome_line?(line) do
    Enum.any?(@chrome_line_patterns, &Regex.match?(&1, line))
  end

  defp tool_invocation_line?(line) do
    Regex.match?(
      ~r/^\s*(?:[⏺✻✳✽✶*]\s*)?(Bash|Read|Update|Edit|Write|Grep|Glob|LS|Task|TodoWrite|WebFetch|WebSearch)\b/u,
      line
    )
  end

  defp tool_result_line?(line) do
    String.starts_with?(line, ["⎿", "… +"])
  end

  defp tool_output_continuation?(raw_line, trimmed) do
    Regex.match?(~r/^\s+/, raw_line) or tool_result_line?(trimmed)
  end

  defp approval_ui_line?(line) do
    Enum.any?(@approval_prompt_patterns, &Regex.match?(&1, line)) or
      Regex.match?(~r/^esc to cancel\b/i, line)
  end

  defp output_after_last_marker(output, marker) do
    case String.split(output, marker) do
      [_output] -> :not_found
      parts -> {:ok, List.last(parts)}
    end
  end

  defp flexible_output_after_last_marker(output, marker) do
    pattern =
      marker
      |> normalize_space()
      |> String.split(" ", trim: true)
      |> Enum.map(&Regex.escape/1)
      |> Enum.join("\\s+")

    with {:ok, regex} <- Regex.compile(pattern, "u"),
         [_ | _] = matches <- Regex.scan(regex, output, capture: :first, return: :index),
         [{start, length}] <- List.last(matches) do
      tail_start = start + length
      {:ok, binary_part(output, tail_start, byte_size(output) - tail_start)}
    else
      _other -> :not_found
    end
  end

  defp normalize_space(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp searchable_text(session, output) do
    [
      output,
      Map.get(session, :title, ""),
      Map.get(session, :current_path, ""),
      Map.get(session, :command, "")
    ]
    |> Enum.join("\n")
  end

  defp result(work_state, signals) do
    %{work_state: work_state, signals: Enum.uniq(signals)}
  end

  defp has_match?(text, patterns), do: Enum.any?(patterns, &Regex.match?(&1, text))

  defp weak_running?(text) do
    has_match?(text, @weak_running_patterns) and not agent_idle_footer?(text)
  end

  defp agent_idle_footer?(text) do
    has_match?(text, @agent_idle_footer_patterns) and not has_match?(text, @running_patterns)
  end

  defp matching_signals(text, groups) do
    groups
    |> Enum.flat_map(fn {name, patterns} ->
      if has_match?(text, patterns), do: [Atom.to_string(name)], else: []
    end)
  end

  defp truncate(value, max_length) do
    if String.length(value) > max_length do
      String.slice(value, 0, max_length - 3) <> "..."
    else
      value
    end
  end
end
