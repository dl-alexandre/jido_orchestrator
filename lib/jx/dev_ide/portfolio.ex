defmodule JX.DevIDE.Portfolio do
  @moduledoc """
  Portfolio-level grouping for DevIDE workspace dossiers.
  """

  alias JX.DevIDE.{Client, Status, Workspace}

  @type t :: %__MODULE__{
          healthy: [Status.t()],
          blocked: [Status.t()],
          needs_review: [Status.t()],
          unknown: [Status.t()],
          total: non_neg_integer()
        }

  defstruct healthy: [], blocked: [], needs_review: [], unknown: [], total: 0

  @spec fetch(Client.t()) :: {:ok, t()} | {:error, Client.Error.t()}
  def fetch(%Client{} = client) do
    fetch_with(client, &Status.fetch/2)
  end

  @doc """
  Fetches portfolio state using only the workspace list and status endpoints.
  """
  @spec fetch_snapshot(Client.t()) :: {:ok, t()} | {:error, Client.Error.t()}
  def fetch_snapshot(%Client{} = client) do
    fetch_with(client, &Status.fetch_snapshot/2)
  end

  defp fetch_with(%Client{} = client, status_fun) when is_function(status_fun, 2) do
    with {:ok, workspace_payloads} <- Client.workspaces(client) do
      workspace_payloads
      |> Enum.map(&Workspace.from_payload/1)
      |> fetch_statuses(client, status_fun, [])
      |> case do
        {:ok, statuses} -> {:ok, from_statuses(statuses)}
        {:error, error} -> {:error, error}
      end
    end
  end

  @spec from_statuses([Status.t()]) :: t()
  def from_statuses(statuses) when is_list(statuses) do
    groups = Enum.group_by(statuses, & &1.status)

    %__MODULE__{
      healthy: sorted(Map.get(groups, :healthy, [])),
      blocked: sorted(Map.get(groups, :blocked, [])),
      needs_review: sorted(Map.get(groups, :needs_review, [])),
      unknown: sorted(Map.get(groups, :unknown, [])),
      total: length(statuses)
    }
  end

  @spec risks(t()) :: [Status.t()]
  def risks(%__MODULE__{} = portfolio) do
    sorted(portfolio.blocked ++ portfolio.needs_review)
  end

  defp fetch_statuses([], _client, _status_fun, acc), do: {:ok, Enum.reverse(acc)}

  defp fetch_statuses([%Workspace{id: id} | rest], client, status_fun, acc) do
    case status_fun.(client, id) do
      {:ok, status} -> fetch_statuses(rest, client, status_fun, [status | acc])
      {:error, error} -> {:error, error}
    end
  end

  defp sorted(statuses) do
    Enum.sort_by(statuses, fn status ->
      {String.downcase(status.workspace.name || ""), status.workspace.id}
    end)
  end
end
