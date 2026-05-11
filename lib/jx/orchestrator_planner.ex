defmodule JX.OrchestratorPlanner do
  @moduledoc """
  Conservative next-step planner for completed agent session reports.

  The planner intentionally handles only narrow continuation work. It can
  chamber prompts for known-safe workflows registered as playbooks, while
  avoiding pushes, merges, deployments, credentials, destructive commands,
  and broad repository decisions.

  Project-specific continuation knowledge lives in playbook modules
  implementing `JX.OrchestratorPlanner.Playbook`. Configure the
  active list via:

      config :jx, :planner_playbooks, [MyApp.Playbooks.Foo]

  When no playbook matches the planner falls back to the generic
  next-step path that lifts the report's own "Next concrete step"
  excerpt into a constrained prompt.
  """

  alias JX.SessionStatus

  @risky_patterns [
    ~r/\bgit\s+push\b|push\s+(the\s+)?(current\s+)?branch|push\s+(existing|local|commit)/i,
    ~r/\bmerge\s+(PR|pull request|branch)|\bmerge\b.*\b(main|master)\b/i,
    ~r/\brebase\b/i,
    ~r/\bforce[- ]?push\b/i,
    ~r/\brelease\b/i,
    ~r/\bdeploy\b/i,
    ~r/\bcredential/i,
    ~r/\bsecret/i,
    ~r/\btoken\b/i,
    ~r/\b(api key|apikey)\b.*\b(configure|set|add|change|rotate|create|update|provide|store|expose|secret|credential)\b|\b(configure|set|add|change|rotate|create|update|provide|store|expose|secret|credential)\b.*\b(api key|apikey)\b/i,
    ~r/\brm\s+-rf\b/i,
    ~r/\bdelete\b/i,
    ~r/\bdrop\b.*\bdatabase\b/i,
    ~r/\bopen\s+an?\s+issue\b/i
  ]

  @baseline_safe_patterns [
    ~r/\bnil-guard\b/i,
    ~r/\bregression test\b/i,
    ~r/\bmix format\b/i,
    ~r/\bmix test\b/i,
    ~r/\bcontext tests?\b/i,
    ~r/\bcoverage target\b/i
  ]

  def plan(profile, observation) do
    output =
      observation
      |> observation_output()
      |> relevant_output(profile)

    with :ok <- candidate_profile(profile),
         :ok <- completed_output(output),
         :ok <- safe_output(output),
         {:ok, prompt, reason} <- prompt_from_output(output),
         :ok <- safe_prompt(prompt) do
      {:ok,
       %{
         safety: "safe",
         prompt_status: "ready",
         prompt: prompt,
         reason: reason,
         evidence: evidence(output)
       }}
    else
      {:skip, reason} -> {:skip, reason}
      :error -> {:skip, "no safe continuation found"}
    end
  end

  def hold(profile, observation) do
    output =
      observation
      |> observation_output()
      |> relevant_output(profile)

    with :ok <- candidate_profile(profile),
         :ok <- completed_output(output),
         :ok <- hold_output(output) do
      {:ok,
       %{
         safety: "manual",
         prompt_status: "blocked",
         reason: "completed report recommends holding for a blocker",
         evidence: evidence(output)
       }}
    else
      {:skip, reason} -> {:skip, reason}
      :error -> {:skip, "no hold recommendation found"}
    end
  end

  def observation_output(%{snapshot: snapshot, summary: summary}) do
    case Jason.decode(snapshot || "") do
      {:ok, %{"capture" => %{"output" => output}}} when is_binary(output) ->
        output

      _other ->
        summary || ""
    end
  end

  def observation_output(%{summary: summary}), do: summary || ""
  def observation_output(_observation), do: ""

  defp relevant_output(output, profile) do
    marker =
      first_present([
        get_in(profile, [:actual, :last_directive, :message]),
        get_in(profile, [:next_prompt, :text])
      ])

    case SessionStatus.response_after_marker(output, marker) do
      {:ok, response} -> response
      :not_found -> output
    end
  end

  defp candidate_profile(profile) do
    cond do
      get_in(profile, [:session, :control_mode]) != "managed" ->
        {:skip, "session is not managed"}

      get_in(profile, [:session, :can_direct]) != true ->
        {:skip, "session is not directable"}

      get_in(profile, [:actual, :work_state]) == "running" ->
        {:skip, "session is still running"}

      get_in(profile, [:next_prompt, :source]) == "profile" and
          get_in(profile, [:next_prompt, :status]) in ["ready", "sent", "blocked"] ->
        {:skip, "profile already has an active prompt"}

      get_in(profile, [:planned, :prompt_status]) in ["ready", "sent", "blocked"] ->
        {:skip, "profile prompt is not open for planning"}

      true ->
        :ok
    end
  end

  defp completed_output(output) do
    cond do
      not present?(output) ->
        {:skip, "no observed output"}

      Regex.match?(~r/running in the background|still running|do you want to proceed\?/i, output) ->
        {:skip, "session output is not complete"}

      Regex.match?(
        ~r/(Status|Current Status|Next concrete step|Recommended follow-up|Next highest-value coverage target)/i,
        output
      ) ->
        :ok

      true ->
        {:skip, "no completed report markers"}
    end
  end

  defp safe_output(output) do
    if Enum.any?(@risky_patterns, &Regex.match?(&1, output)) do
      {:skip, "completed report includes manual-risk terms"}
    else
      :ok
    end
  end

  defp hold_output(output) do
    hold_recommendation? =
      Regex.match?(~r/^\s*Hold\.|Next concrete step\s+Hold\b|Next safe step.*Hold\b/is, output) or
        Regex.match?(~r/no action .* needed|nothing .* can (fix|clear|move)/i, output) or
        Regex.match?(~r/no rerun, push, merge, or code change/i, output) or
        Regex.match?(
          ~r/requires user authorization|Pause here for direction|Stopping work and escalating|without authorization/i,
          output
        )

    blocker_context? =
      Regex.match?(
        ~r/upstream|environmental flake|blocker|blocked|wait for|manual|authorization|authorize|direction/i,
        output
      )

    if hold_recommendation? and blocker_context? do
      :ok
    else
      {:skip, "completed report does not recommend holding"}
    end
  end

  defp safe_prompt(prompt) do
    cond do
      Enum.any?(@risky_patterns, &Regex.match?(&1, prompt)) ->
        {:skip, "planned prompt includes manual-risk terms"}

      Enum.any?(safe_patterns(), &Regex.match?(&1, prompt)) ->
        :ok

      true ->
        {:skip, "planned prompt is not in a known safe workflow"}
    end
  end

  defp safe_patterns do
    @baseline_safe_patterns ++ playbook_safe_patterns()
  end

  defp playbook_safe_patterns do
    Enum.flat_map(playbooks(), fn module ->
      if function_exported?(module, :safe_pattern, 0) do
        case module.safe_pattern() do
          nil -> []
          %Regex{} = regex -> [regex]
          _other -> []
        end
      else
        []
      end
    end)
  end

  defp prompt_from_output(output) do
    cond do
      hold_output(output) == :ok ->
        {:skip, "completed report recommends holding"}

      playbook = matching_playbook(output) ->
        case playbook.prompt_for(output) do
          {:ok, prompt, reason} -> {:ok, prompt, reason}
          :error -> generic_next_step_prompt(output)
        end

      true ->
        generic_next_step_prompt(output)
    end
  end

  defp matching_playbook(output) do
    Enum.find(playbooks(), fn module ->
      Code.ensure_loaded?(module) and function_exported?(module, :match?, 1) and
        module.match?(output)
    end)
  end

  defp playbooks do
    Application.get_env(:jx, :planner_playbooks, [])
  end

  defp generic_next_step_prompt(output) do
    case next_step_excerpt(output) do
      "" ->
        :error

      excerpt ->
        prompt =
          "Proceed with the next concrete step from your report. Keep scope narrow and preserve unrelated dirty files. Scope: #{excerpt} Run mix format on touched files and the most targeted relevant tests. Report changed files, test results, blockers, and the next highest-value target. Do not push."

        {:ok, prompt, "continue explicit next concrete step"}
    end
  end

  defp next_step_excerpt(output) do
    output
    |> section_after(~r/(Next concrete step|Recommended follow-up)\s*/i)
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(6)
    |> Enum.join(" ")
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 500)
    |> Kernel.||("")
  end

  defp section_after(output, pattern) do
    case Regex.split(pattern, output, parts: 2, include_captures: false) do
      [_before, after_section] -> after_section
      _other -> ""
    end
  end

  defp evidence(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&evidence_line?/1)
    |> Enum.take(6)
  end

  defp evidence_line?(line) do
    present?(line) and
      Regex.match?(
        ~r/(Next concrete step|Recommended follow-up|Recommend:|nil-guard|mix test|mix format|coverage target|Hold\.|upstream|environmental flake|blocker)/i,
        line
      )
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp first_present(values) do
    Enum.find_value(values, "", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: false, else: value

      _other ->
        false
    end)
  end
end
