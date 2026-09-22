defmodule CleatDeploy.ServersTest do
  use CleatDeploy.DataCase

  import Mox

  alias CleatDeploy.AWS.Lightsail.InstanceSpec
  alias CleatDeploy.HetznerMock
  alias CleatDeploy.Servers
  alias CleatDeploy.Servers.SshKeys
  alias CleatDeploy.TenancyFixtures

  setup :verify_on_exit!

  setup do
    %{scope: TenancyFixtures.scope_fixture()}
  end

  describe "create_server/2" do
    test "persists a valid server", %{scope: scope} do
      attrs = %{
        name: "trip-planner",
        host_ip: "100.59.80.29",
        ssh_user: "ubuntu",
        region: "us-east-1"
      }

      assert {:ok, server} = Servers.create_server(scope, attrs)
      assert server.name == "trip-planner"
      assert server.tenant_id == scope.tenant.id
    end

    test "encrypts SSH private key", %{scope: scope} do
      attrs = %{
        name: "trip-planner",
        host_ip: "100.59.80.29",
        ssh_user: "ubuntu",
        region: "us-east-1",
        ssh_private_key: "-----BEGIN TEST KEY-----\nsecret\n-----END TEST KEY-----"
      }

      assert {:ok, server} = Servers.create_server(scope, attrs)
      server = Servers.get_server!(scope, server.id)
      assert Servers.ssh_key_configured?(server)
    end

    test "accepts a hetzner provider", %{scope: scope} do
      attrs = %{
        name: "gestaobem-cx33",
        host_ip: "203.0.113.10",
        ssh_user: "ubuntu",
        region: "fsn1",
        provider: "hetzner",
        aws_instance_name: "gestaobem-cx33"
      }

      assert {:ok, server} = Servers.create_server(scope, attrs)
      assert server.provider == "hetzner"
      assert server.region == "fsn1"
    end

    test "formats hetzner prices in euro", %{scope: scope} do
      attrs = %{
        name: "gestaobem-cx33-price",
        host_ip: "203.0.113.11",
        ssh_user: "ubuntu",
        region: "fsn1",
        provider: "hetzner",
        monthly_price_usd: Decimal.new("7.59")
      }

      assert {:ok, server} = Servers.create_server(scope, attrs)
      assert Servers.Server.format_price(server) == "€7.59/mo"
    end

    test "rejects unknown provider", %{scope: scope} do
      attrs = %{
        name: "bad-provider",
        host_ip: "10.0.0.1",
        ssh_user: "ubuntu",
        region: "fsn1",
        provider: "digitalocean"
      }

      assert {:error, changeset} = Servers.create_server(scope, attrs)
      assert "is invalid" in errors_on(changeset).provider
    end

    test "rejects invalid IP", %{scope: scope} do
      attrs = %{
        name: "bad",
        host_ip: "not-an-ip",
        ssh_user: "ubuntu",
        region: "us-east-1"
      }

      assert {:error, changeset} = Servers.create_server(scope, attrs)
      assert "is invalid" in errors_on(changeset).host_ip
    end
  end

  describe "provision_server/2" do
    test "creates a Hetzner VM and stores the assigned IP", %{scope: scope} do
      {:ok, keys} = SshKeys.generate()

      TenancyFixtures.server_fixture(scope, %{
        name: "seed-key",
        ssh_private_key: keys.private
      })

      expect(HetznerMock, :create_instance, fn attrs ->
        assert attrs.name == "app-box"
        assert attrs.location == "fsn1"
        assert attrs.server_type == "cx33"
        assert attrs.ssh_public_keys == [keys.public]

        {:ok,
         %InstanceSpec{
           bundle_id: "cx33",
           bundle_name: "CX33",
           cpu_count: 4,
           ram_mb: 8192,
           disk_gb: 80,
           status: "running",
           blueprint_name: "Ubuntu 24.04",
           monthly_price_usd: Decimal.new("7.59"),
           name: "app-box",
           public_ip: "167.233.201.44",
           region: "fsn1"
         }}
      end)

      assert {:ok, server} =
               Servers.provision_server(scope, %{
                 "name" => "App Box",
                 "region" => "fsn1",
                 "bundle_id" => "cx33",
                 "deploy_mode" => "shared"
               })

      assert server.name == "app-box"
      assert server.host_ip == "167.233.201.44"
      assert server.provider == "hetzner"
      assert server.bundle_id == "cx33"
      assert server.instance_status == "running"
      assert Servers.ssh_key_configured?(server)
    end

    test "rejects an invalid server name without calling Hetzner", %{scope: scope} do
      assert {:error, changeset} =
               Servers.provision_server(scope, %{
                 "name" => "1box",
                 "region" => "fsn1",
                 "bundle_id" => "cx33",
                 "deploy_mode" => "shared"
               })

      assert changeset.action == :insert
    end
  end

  describe "update_host_ip/2" do
    test "updates the stored IPv4 address", %{scope: scope} do
      server = TenancyFixtures.server_fixture(scope, %{host_ip: "52.0.157.89"})

      assert {:ok, updated} = Servers.update_host_ip(server, "52.73.89.19")
      assert updated.host_ip == "52.73.89.19"
    end

    test "rejects an invalid IP", %{scope: scope} do
      server = TenancyFixtures.server_fixture(scope, %{host_ip: "10.0.0.1"})
      assert {:error, changeset} = Servers.update_host_ip(server, "not-an-ip")
      assert "is invalid" in errors_on(changeset).host_ip
    end
  end

  describe "provision cloud-init" do
    test "opens every port Caddy needs, HTTP/3 included" do
      user_data = CleatDeploy.Servers.Provision.user_data("ssh-ed25519 AAAA test@cleat")

      assert user_data =~ "ssh_authorized_keys"
      assert user_data =~ "- [ufw, allow, OpenSSH]"
      assert user_data =~ "- [ufw, allow, 80/tcp]"
      assert user_data =~ "- [ufw, allow, 443/tcp]"
      # Caddy serves HTTP/3 on UDP 443 and advertises it via `alt-svc`: with the
      # port closed a browser that takes the offer fails with
      # ERR_SSL_PROTOCOL_ERROR even though HTTPS over TCP answers fine.
      assert user_data =~ "- [ufw, allow, 443/udp]"
    end
  end
end
