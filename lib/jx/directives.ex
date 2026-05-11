defmodule JX.Directives do
  @moduledoc """
  Persistence operations for audited agent directives.

  These records are not `Jido.Agent.Directive` runtime effects. New code should
  prefer `JX.OperatorDirectives` when referring to persisted tmux or
  task instructions.
  """

  import Ecto.Query

  alias JX.Directives.Directive
  alias JX.Hosts.Host
  alias JX.Repo

  def insert_directive(attrs) do
    attrs =
      attrs
      |> Map.put_new(:directive_id, directive_id())
      |> Map.put_new(:task_ref, "")
      |> Map.put_new(:error, "")

    %Directive{}
    |> Directive.changeset(attrs)
    |> Repo.insert()
  end

  def list_directives(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Directive
    |> maybe_filter_host(Keyword.get(opts, :host_name))
    |> maybe_filter_task(Keyword.get(opts, :task_ref))
    |> order_by([directive], desc: directive.id)
    |> limit(^limit)
    |> preload([:host])
    |> Repo.all()
  end

  defp maybe_filter_host(query, nil), do: query

  defp maybe_filter_host(query, host_name) do
    query
    |> join(:inner, [directive], host in Host, on: directive.host_id == host.id)
    |> where([_directive, host], host.name == ^host_name)
  end

  defp maybe_filter_task(query, nil), do: query

  defp maybe_filter_task(query, task_ref),
    do: where(query, [directive], directive.task_ref == ^task_ref)

  defp directive_id do
    random =
      5
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    "dir-" <> random
  end
end
