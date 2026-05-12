defmodule JX.CLI.LeasesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Leases

  defmodule FakeWorkspace do
    def list_leases(opts) do
      send(self(), {:list_leases, opts})
      [lease(%{})]
    end

    def acquire_lease(resource_type, resource_id, owner, opts) do
      send(self(), {:acquire_lease, resource_type, resource_id, owner, opts})

      {:ok,
       lease(%{
         resource_type: resource_type,
         resource_id: resource_id,
         owner: owner,
         reason: opts[:reason]
       })}
    end

    def release_lease(lease_id, owner) do
      send(self(), {:release_lease, lease_id, owner})
      {:ok, lease(%{lease_id: lease_id, owner: owner, status: "released"})}
    end

    def reassign_lease(resource_type, resource_id, owner, opts) do
      send(self(), {:reassign_lease, resource_type, resource_id, owner, opts})

      {:ok,
       lease(%{
         lease_id: "lease-reassigned",
         resource_type: resource_type,
         resource_id: resource_id,
         owner: owner,
         status: "reassigned",
         reason: opts[:reason]
       })}
    end

    defp lease(attrs) do
      %{
        lease_id: Map.get(attrs, :lease_id, "lease-1"),
        resource_type: Map.get(attrs, :resource_type, "workspace"),
        resource_id: Map.get(attrs, :resource_id, "workspace-1"),
        owner: Map.get(attrs, :owner, "agent-1"),
        status: Map.get(attrs, :status, "active"),
        correlation_id: "corr-1",
        reason: Map.get(attrs, :reason, "coverage"),
        acquired_at: nil,
        expires_at: nil,
        released_at: nil,
        reassigned_at: nil
      }
    end
  end

  test "leases ls owns filters and json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Leases.run(
                   [
                     "ls",
                     "--owner",
                     "agent-1",
                     "--status",
                     "active",
                     "--resource",
                     "workspace:workspace-1",
                     "--stale",
                     "-n",
                     "10",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:list_leases, opts}
    assert opts[:owner] == "agent-1"
    assert opts[:status] == "active"
    assert opts[:resource_type] == "workspace"
    assert opts[:resource_id] == "workspace-1"
    assert opts[:stale] == true
    assert opts[:limit] == 10

    assert %{"leases" => [%{"lease_id" => "lease-1", "status" => "active"}]} =
             Jason.decode!(output)
  end

  test "leases ls validates status before starting the app" do
    assert {:error, message} =
             Leases.run(["ls", "--status", "bad"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported lease status"
    refute_received :started
    refute_received :list_leases
  end

  test "leases ls validates resource filter before starting the app" do
    assert {:error, message} =
             Leases.run(["ls", "--resource", "bad"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "resource must look like approval:<id>, action:<id>, or workspace:<id>"
    refute_received :started
    refute_received :list_leases
  end

  test "leases acquire parses ttl reason and renders json" do
    output =
      capture_io(fn ->
        assert :ok =
                 Leases.run(
                   [
                     "acquire",
                     "workspace",
                     "workspace-1",
                     "--owner",
                     "agent-1",
                     "--ttl-seconds",
                     "300",
                     "--reason",
                     "coverage",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:acquire_lease, "workspace", "workspace-1", "agent-1", opts}
    assert opts[:ttl_seconds] == 300
    assert opts[:reason] == "coverage"

    assert %{
             "lease_id" => "lease-1",
             "resource_type" => "workspace",
             "resource_id" => "workspace-1",
             "owner" => "agent-1"
           } = Jason.decode!(output)
  end

  test "leases acquire requires owner before starting the app" do
    assert {:error, message} =
             Leases.run(["acquire", "workspace", "workspace-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "--owner is required"
    refute_received :started
    refute_received :acquire_lease
  end

  test "leases acquire validates ttl before starting the app" do
    assert {:error, message} =
             Leases.run(
               [
                 "acquire",
                 "workspace",
                 "workspace-1",
                 "--owner",
                 "agent-1",
                 "--ttl-seconds",
                 "0"
               ],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "ttl-seconds must be a positive integer"
    refute_received :started
    refute_received :acquire_lease
  end

  test "leases release requires owner before starting the app" do
    assert {:error, message} =
             Leases.run(["release", "lease-1"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "--owner is required"
    refute_received :started
    refute_received :release_lease
  end

  test "leases release calls workspace and renders stable text" do
    output =
      capture_io(fn ->
        assert :ok =
                 Leases.run(["release", "lease-1", "--owner", "agent-1"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:release_lease, "lease-1", "agent-1"}
    assert output =~ "released lease-1"
    assert output =~ "resource: workspace:workspace-1"
    assert output =~ "owner: agent-1"
    assert output =~ "status: released"
  end

  test "leases reassign passes default ttl and reason" do
    output =
      capture_io(fn ->
        assert :ok =
                 Leases.run(["reassign", "action", "act-1", "--owner", "runner-1", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:reassign_lease, "action", "act-1", "runner-1", opts}
    assert opts[:ttl_seconds] == 900
    assert opts[:reason] == ""

    assert %{
             "lease_id" => "lease-reassigned",
             "resource_type" => "action",
             "resource_id" => "act-1",
             "owner" => "runner-1",
             "status" => "reassigned"
           } = Jason.decode!(output)
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
