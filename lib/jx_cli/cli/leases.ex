defmodule JX.CLI.Leases do
  @moduledoc false

  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @leases_ls_usage "jx leases ls [--owner <owner>] [--status active|released|expired|reassigned|all] [--resource approval:<id>|action:<id>|workspace:<id>] [--stale] [-n 50] [--json]"
  @leases_acquire_usage "jx leases acquire approval|action|workspace <id> --owner <owner> [--ttl-seconds 900] [--json]"
  @leases_release_usage "jx leases release <lease-id> --owner <owner> [--json]"
  @leases_reassign_usage "jx leases reassign approval|action|workspace <id> --owner <owner> [--ttl-seconds 900] [--json]"

  def usage_lines do
    [
      @leases_ls_usage,
      @leases_acquire_usage,
      @leases_release_usage,
      @leases_reassign_usage
    ]
  end

  def usage do
    Enum.join(usage_lines(), " | ")
  end

  def run(["ls" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          owner: :string,
          status: :string,
          resource: :string,
          stale: :boolean,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @leases_ls_usage),
         :ok <- validate_optional_lease_status(parsed[:status]),
         {:ok, resource_type, resource_id} <- lease_resource_filter(parsed[:resource]),
         :ok <- validate_positive("n", limit),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:list_leases, [
        [
          owner: parsed[:owner],
          status: parsed[:status],
          resource_type: resource_type,
          resource_id: resource_id,
          stale: parsed[:stale] || false,
          limit: limit
        ]
      ])
      |> print_leases(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["acquire", resource_type, resource_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [owner: :string, ttl_seconds: :integer, reason: :string, json: :boolean]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @leases_acquire_usage),
         :ok <- validate_required_option("owner", parsed[:owner]),
         :ok <- validate_optional_positive("ttl-seconds", parsed[:ttl_seconds]),
         :ok <- start_app(opts),
         {:ok, lease} <-
           apply(workspace(opts), :acquire_lease, [
             resource_type,
             resource_id,
             parsed[:owner],
             [
               ttl_seconds: parsed[:ttl_seconds] || 15 * 60,
               reason: parsed[:reason] || ""
             ]
           ]) do
      print_lease("acquired", lease, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["release", lease_id | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [owner: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @leases_release_usage),
         :ok <- validate_required_option("owner", parsed[:owner]),
         :ok <- start_app(opts),
         {:ok, lease} <-
           apply(workspace(opts), :release_lease, [lease_id, parsed[:owner]]) do
      print_lease("released", lease, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["reassign", resource_type, resource_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [owner: :string, ttl_seconds: :integer, reason: :string, json: :boolean]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @leases_reassign_usage),
         :ok <- validate_required_option("owner", parsed[:owner]),
         :ok <- validate_optional_positive("ttl-seconds", parsed[:ttl_seconds]),
         :ok <- start_app(opts),
         {:ok, lease} <-
           apply(workspace(opts), :reassign_lease, [
             resource_type,
             resource_id,
             parsed[:owner],
             [
               ttl_seconds: parsed[:ttl_seconds] || 15 * 60,
               reason: parsed[:reason] || ""
             ]
           ]) do
      print_lease("reassigned", lease, json: parsed[:json] || false)
      :ok
    end
  end

  def run(_args, _opts), do: {:error, "usage: #{usage()}"}

  defp workspace(opts), do: Keyword.get(opts, :workspace, Workspace)

  defp start_app(opts) do
    case Keyword.fetch(opts, :start_app) do
      {:ok, start_app} -> start_app.()
      :error -> {:error, :missing_start_app_callback}
    end
  end

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp validate_optional_positive(_name, nil), do: :ok
  defp validate_optional_positive(name, value), do: validate_positive(name, value)

  defp validate_required_option(name, nil), do: {:error, "--#{name} is required"}
  defp validate_required_option(name, ""), do: {:error, "--#{name} is required"}
  defp validate_required_option(_name, _value), do: :ok

  defp validate_optional_lease_status(nil), do: :ok

  defp validate_optional_lease_status(status)
       when status in ~w(active released expired reassigned all),
       do: :ok

  defp validate_optional_lease_status(status),
    do:
      {:error,
       "unsupported lease status #{inspect(status)}; expected active, released, expired, reassigned, or all"}

  defp lease_resource_filter(nil), do: {:ok, nil, nil}

  defp lease_resource_filter(resource) do
    case String.split(resource, ":", parts: 2) do
      [type, id] when type in ~w(approval action workspace) and id != "" -> {:ok, type, id}
      _other -> {:error, "resource must look like approval:<id>, action:<id>, or workspace:<id>"}
    end
  end

  defp print_leases(leases, opts) do
    if opts[:json] do
      print_json(%{leases: Enum.map(leases, &json_lease/1)})
    else
      if leases == [] do
        IO.puts("no leases")
      else
        rows =
          Enum.map(leases, fn lease ->
            [
              lease.lease_id,
              lease.resource_type,
              lease.resource_id,
              lease.owner,
              lease.status,
              lease.correlation_id,
              format_time(lease.expires_at)
            ]
          end)

        print_table(["ID", "TYPE", "RESOURCE", "OWNER", "STATUS", "CORRELATION", "EXPIRES"], rows)
      end
    end
  end

  defp print_lease(label, lease, opts) do
    if opts[:json] do
      print_json(json_lease(lease))
    else
      IO.puts("#{label} #{lease.lease_id}")
      IO.puts("resource: #{lease.resource_type}:#{lease.resource_id}")
      IO.puts("owner: #{lease.owner}")
      IO.puts("status: #{lease.status}")
      IO.puts("correlation_id: #{lease.correlation_id}")
      IO.puts("expires_at: #{format_time(lease.expires_at)}")
    end
  end

  defp json_lease(lease) do
    %{
      lease_id: lease.lease_id,
      resource_type: lease.resource_type,
      resource_id: lease.resource_id,
      owner: lease.owner,
      status: lease.status,
      correlation_id: lease.correlation_id,
      reason: lease.reason,
      acquired_at: lease.acquired_at,
      expires_at: lease.expires_at,
      released_at: lease.released_at,
      reassigned_at: lease.reassigned_at
    }
  end

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value) when is_binary(value), do: if(value == "", do: "-", else: value)
end
