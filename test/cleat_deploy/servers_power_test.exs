defmodule CleatDeploy.ServersPowerTest do
  use CleatDeploy.DataCase, async: false

  import Mox

  alias CleatDeploy.AWS.Lightsail.InstanceSpec
  alias CleatDeploy.AWS.LightsailMock
  alias CleatDeploy.HetznerMock
  alias CleatDeploy.Servers
  alias CleatDeploy.TenancyFixtures

  setup :verify_on_exit!

  setup do
    %{scope: TenancyFixtures.scope_fixture()}
  end

  test "stops a Lightsail instance and refreshes its status", %{scope: scope} do
    server =
      TenancyFixtures.server_fixture(scope, %{aws_instance_name: "vm1", region: "us-east-1"})

    expect(LightsailMock, :power, fn "us-east-1", "vm1", :stop -> :ok end)

    expect(LightsailMock, :get_instance, fn "us-east-1", "vm1" ->
      {:ok, spec("stopped")}
    end)

    assert {:ok, updated} = Servers.power(scope, server, :stop)
    assert updated.instance_status == "stopped"
  end

  test "starts a Hetzner instance", %{scope: scope} do
    server =
      TenancyFixtures.server_fixture(scope, %{
        aws_instance_name: "cx33",
        provider: "hetzner",
        region: "fsn1"
      })

    expect(HetznerMock, :power, fn "cx33", :start -> :ok end)

    expect(HetznerMock, :get_instance, fn "fsn1", "cx33" ->
      {:ok, spec("running")}
    end)

    assert {:ok, updated} = Servers.power(scope, server, :start)
    assert updated.instance_status == "running"
  end

  test "returns unauthorized for another tenant", %{scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    other = TenancyFixtures.scope_fixture()

    assert {:error, :unauthorized} = Servers.power(other, server, :stop)
  end

  test "errors when the instance name is missing", %{scope: scope} do
    server = TenancyFixtures.server_fixture(scope, %{aws_instance_name: nil})

    assert {:error, :missing_instance_name} = Servers.power(scope, server, :start)
  end

  defp spec(status) do
    %InstanceSpec{
      bundle_id: "nano_3_0",
      bundle_name: "Nano",
      cpu_count: 2,
      ram_mb: 512,
      disk_gb: 20,
      status: status,
      blueprint_name: "Ubuntu",
      monthly_price_usd: Decimal.new("5.00")
    }
  end
end
