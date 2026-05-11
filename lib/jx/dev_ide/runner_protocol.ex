defmodule JX.DevIDE.RunnerProtocol do
  @moduledoc """
  JX view of the DevIDE runner protocol v1 contract.

  JX may decide that approved work should be delegated, but DevIDE remains the
  execution authority. This module only validates envelopes, status values, and
  normalized failure classes; it never resolves argv or executes work.
  """

  @protocol "jx.runner.v1"
  @assignment_statuses ~w(queued claimed running succeeded failed expired abandoned)
  @terminal_statuses ~w(succeeded failed expired abandoned)
  @failure_classes ~w(
    enqueue_failed
    claim_rejected
    lease_expired
    report_rejected
    action_failed
    replay_mismatch
    runner_lost
  )

  def protocol, do: @protocol
  def assignment_statuses, do: @assignment_statuses
  def terminal_statuses, do: @terminal_statuses
  def failure_classes, do: @failure_classes
  def terminal_status?(status), do: status in @terminal_statuses

  def failure_class(:enqueue_failed), do: "enqueue_failed"
  def failure_class(:claim_rejected), do: "claim_rejected"
  def failure_class(:lease_expired), do: "lease_expired"
  def failure_class(:report_rejected), do: "report_rejected"
  def failure_class(:action_failed), do: "action_failed"
  def failure_class(:replay_mismatch), do: "replay_mismatch"
  def failure_class(:runner_lost), do: "runner_lost"
  def failure_class({:replay_mismatch, _reason}), do: "replay_mismatch"
  def failure_class({:malformed_devide_response, _reason}), do: "replay_mismatch"
  def failure_class({:assignment_closed, _status}), do: "report_rejected"
  def failure_class({:action_not_assignable, _status}), do: "enqueue_failed"
  def failure_class({:unsupported_devide_runner_safe_action, _kind}), do: "enqueue_failed"
  def failure_class(:missing_command_id), do: "enqueue_failed"
  def failure_class(:assignment_not_found), do: "enqueue_failed"
  def failure_class(_reason), do: "report_rejected"

  def report_failure_class(report) when is_map(report) do
    get_in(report, ["evidence", "failure_class"]) ||
      get_in(report, [:evidence, "failure_class"]) ||
      if(text_field(report, "event") == "failed", do: "action_failed")
  end

  def assignment_failure_class(assignment) when is_map(assignment) do
    text_field(assignment, "failure_class") ||
      get_in(assignment, ["evidence", "failure_class"]) ||
      get_in(assignment, [:evidence, "failure_class"]) ||
      if(text_field(assignment, "status") == "failed", do: "action_failed")
  end

  def validate_replay(replay, expected) when is_map(replay) and is_map(expected) do
    assignment = field(replay, "assignment") || %{}
    metadata = field(assignment, "metadata") || %{}

    cond do
      field(replay, "protocol") != @protocol ->
        {:error, {:replay_mismatch, :protocol}}

      text_field(assignment, "id") == "" ->
        {:error, {:replay_mismatch, :missing_assignment_id}}

      text_field(assignment, "workspace_id") != text_field(expected, "workspace_id") ->
        {:error, {:replay_mismatch, :workspace_id}}

      text_field(metadata, "jx_assignment_id") != text_field(expected, "assignment_id") ->
        {:error, {:replay_mismatch, :jx_assignment_id}}

      expected_action_id(expected) != "" and
          text_field(metadata, "jx_action_id") != expected_action_id(expected) ->
        {:error, {:replay_mismatch, :jx_action_id}}

      text_field(assignment, "status") not in @assignment_statuses ->
        {:error, {:replay_mismatch, :status}}

      not reports_valid?(field(replay, "reports")) ->
        {:error, {:replay_mismatch, :reports}}

      true ->
        :ok
    end
  end

  def validate_replay(_replay, _expected), do: {:error, {:replay_mismatch, :non_map}}

  defp reports_valid?(reports) when is_list(reports) do
    Enum.with_index(reports, 1)
    |> Enum.all?(fn {report, position} ->
      is_map(report) and text_field(report, "event") != "" and
        text_field(report, "runner_id") != "" and
        report_position(report) == position
    end)
  end

  defp reports_valid?(_reports), do: false

  defp report_position(report) do
    case field(report, "position") do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp expected_action_id(expected), do: text_field(expected, "action_id")

  defp text_field(map, key) when is_map(map) do
    case field(map, key) do
      value when value in [nil, ""] -> ""
      value -> to_string(value)
    end
  end

  defp text_field(_map, _key), do: ""

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
