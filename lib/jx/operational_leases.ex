defmodule JX.OperationalLeases do
  @moduledoc """
  Durable leases/claims for approvals and safe actions.

  Leases prevent conflicting operator work across sessions. Lease changes are
  also mirrored into the append-only operational event stream.
  """

  import Ecto.Query

  alias JX.OperationalEvents
  alias JX.OperationalLeases.Lease
  alias JX.Repo

  @lease_prefix "lease-"
  @default_ttl_seconds 15 * 60

  def statuses, do: Lease.statuses()
  def resource_types, do: Lease.resource_types()

  def acquire(resource_type, resource_id, owner, opts \\ []) do
    resource_type = normalize_text(resource_type)
    resource_id = normalize_text(resource_id)
    owner = normalize_text(owner)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    correlation_id = Keyword.get(opts, :correlation_id, OperationalEvents.correlation_id())

    with :ok <- validate_resource(resource_type),
         :ok <- validate_present("resource_id", resource_id),
         :ok <- validate_present("owner", owner),
         :ok <- validate_ttl(ttl_seconds) do
      Repo.transaction(fn ->
        expire_resource_stale(resource_type, resource_id, now)

        case active_for(resource_type, resource_id, now) do
          %Lease{} = lease ->
            Repo.rollback({:lease_conflict, lease})

          nil ->
            lease =
              %Lease{}
              |> Lease.changeset(%{
                lease_id: lease_id(),
                resource_type: resource_type,
                resource_id: resource_id,
                active_key: active_key(resource_type, resource_id),
                owner: owner,
                status: "active",
                correlation_id: correlation_id,
                reason: Keyword.get(opts, :reason, ""),
                metadata: encode_json(Keyword.get(opts, :metadata, %{})),
                acquired_at: now,
                expires_at: DateTime.add(now, ttl_seconds, :second)
              })
              |> Repo.insert()
              |> case do
                {:ok, lease} -> lease
                {:error, changeset} -> Repo.rollback(changeset)
              end

            _ = OperationalEvents.record_lease(lease, "lease.acquired")
            lease
        end
      end)
      |> unwrap_transaction()
    end
  end

  def release(lease_id, owner, opts \\ []) do
    owner = normalize_text(owner)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- validate_present("lease_id", lease_id),
         :ok <- validate_present("owner", owner) do
      Repo.transaction(fn ->
        case Repo.get_by(Lease, lease_id: lease_id) do
          nil ->
            Repo.rollback(:lease_not_found)

          %Lease{status: status} when status != "active" ->
            Repo.rollback({:lease_not_active, status})

          %Lease{owner: lease_owner} = lease ->
            if lease_owner != owner and not Keyword.get(opts, :force, false) do
              Repo.rollback({:lease_owner_mismatch, lease_owner})
            else
              release_active_lease(lease, now)
            end
        end
      end)
      |> unwrap_transaction()
    end
  end

  def reassign(resource_type, resource_id, owner, opts \\ []) do
    resource_type = normalize_text(resource_type)
    resource_id = normalize_text(resource_id)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    with :ok <- validate_resource(resource_type),
         :ok <- validate_present("resource_id", resource_id),
         :ok <- validate_ttl(ttl_seconds) do
      Repo.transaction(fn ->
        case active_for(resource_type, resource_id, now) do
          nil ->
            :ok

          %Lease{} = lease ->
            reassigned =
              lease
              |> Lease.changeset(%{
                status: "reassigned",
                active_key: nil,
                reassigned_at: now
              })
              |> Repo.update()
              |> case do
                {:ok, lease} -> lease
                {:error, changeset} -> Repo.rollback(changeset)
              end

            _ = OperationalEvents.record_lease(reassigned, "lease.reassigned")
            :ok
        end

        case acquire(resource_type, resource_id, owner, Keyword.put(opts, :now, now)) do
          {:ok, lease} -> lease
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> unwrap_transaction()
    end
  end

  def authorize(resource_type, resource_id, owner, opts \\ []) do
    resource_type = normalize_text(resource_type)
    resource_id = normalize_text(resource_id)
    owner = normalize_text(owner)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    expire_resource_stale(resource_type, resource_id, now)

    case active_for(resource_type, resource_id, now) do
      nil ->
        :ok

      %Lease{owner: ^owner} ->
        :ok

      %Lease{} = lease ->
        {:error, {:lease_conflict, lease}}
    end
  end

  def list(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    _ = expire_all(now)
    limit = Keyword.get(opts, :limit, 50)

    Lease
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_owner(Keyword.get(opts, :owner))
    |> maybe_filter_resource(Keyword.get(opts, :resource_type), Keyword.get(opts, :resource_id))
    |> maybe_filter_stale(Keyword.get(opts, :stale), now)
    |> order_by([lease],
      asc:
        fragment(
          "case ? when 'active' then 0 when 'expired' then 1 when 'released' then 2 else 3 end",
          lease.status
        ),
      asc: lease.expires_at,
      desc: lease.updated_at
    )
    |> limit(^limit)
    |> Repo.all()
  end

  def active(resource_type, resource_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    expire_resource_stale(resource_type, resource_id, now)
    active_for(resource_type, resource_id, now)
  end

  def expire_all(now \\ DateTime.utc_now()) do
    Lease
    |> where([lease], lease.status == "active")
    |> where([lease], lease.expires_at <= ^now)
    |> Repo.all()
    |> Enum.map(&expire_lease(&1, now))
  end

  def active_key(resource_type, resource_id), do: "#{resource_type}:#{resource_id}"

  defp expire_resource_stale(resource_type, resource_id, now) do
    Lease
    |> where([lease], lease.active_key == ^active_key(resource_type, resource_id))
    |> where([lease], lease.status == "active")
    |> where([lease], lease.expires_at <= ^now)
    |> Repo.all()
    |> Enum.each(&expire_lease(&1, now))
  end

  defp expire_lease(%Lease{} = lease, now) do
    lease =
      lease
      |> Lease.changeset(%{status: "expired", active_key: nil, released_at: now})
      |> Repo.update!()

    _ = OperationalEvents.record_lease(lease, "lease.expired", severity: "warning")
    lease
  end

  defp release_active_lease(%Lease{} = lease, now) do
    lease =
      lease
      |> Lease.changeset(%{
        status: "released",
        active_key: nil,
        released_at: now
      })
      |> Repo.update()
      |> case do
        {:ok, lease} -> lease
        {:error, changeset} -> Repo.rollback(changeset)
      end

    _ = OperationalEvents.record_lease(lease, "lease.released")
    lease
  end

  defp active_for(resource_type, resource_id, now) do
    Lease
    |> where([lease], lease.active_key == ^active_key(resource_type, resource_id))
    |> where([lease], lease.status == "active")
    |> where([lease], lease.expires_at > ^now)
    |> order_by([lease], desc: lease.acquired_at)
    |> limit(1)
    |> Repo.one()
  end

  defp maybe_filter_status(query, nil), do: where(query, [lease], lease.status == "active")
  defp maybe_filter_status(query, "all"), do: query
  defp maybe_filter_status(query, status), do: where(query, [lease], lease.status == ^status)

  defp maybe_filter_owner(query, nil), do: query
  defp maybe_filter_owner(query, owner), do: where(query, [lease], lease.owner == ^owner)

  defp maybe_filter_resource(query, nil, _resource_id), do: query

  defp maybe_filter_resource(query, resource_type, nil),
    do: where(query, [lease], lease.resource_type == ^resource_type)

  defp maybe_filter_resource(query, resource_type, resource_id) do
    where(
      query,
      [lease],
      lease.resource_type == ^resource_type and lease.resource_id == ^resource_id
    )
  end

  defp maybe_filter_stale(query, true, _now),
    do: where(query, [lease], lease.status == "expired")

  defp maybe_filter_stale(query, _stale, _now), do: query

  defp validate_resource(resource_type) do
    if resource_type in Lease.resource_types(),
      do: :ok,
      else: {:error, {:unsupported_lease_resource, resource_type}}
  end

  defp validate_present(label, value) when value in [nil, ""],
    do: {:error, {:missing_required, label}}

  defp validate_present(_label, _value), do: :ok

  defp validate_ttl(ttl_seconds) when is_integer(ttl_seconds) and ttl_seconds > 0, do: :ok
  defp validate_ttl(ttl_seconds), do: {:error, {:invalid_ttl_seconds, ttl_seconds}}

  defp unwrap_transaction({:ok, lease}), do: {:ok, lease}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp normalize_text(nil), do: ""
  defp normalize_text(value), do: value |> to_string() |> String.trim()

  defp encode_json(value) do
    Jason.encode!(value)
  rescue
    Protocol.UndefinedError -> "{}"
    ArgumentError -> "{}"
  end

  defp lease_id do
    random =
      5
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    @lease_prefix <> random
  end
end
