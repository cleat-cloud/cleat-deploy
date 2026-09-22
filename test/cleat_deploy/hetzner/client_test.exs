defmodule CleatDeploy.Hetzner.ClientTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.AWS.Lightsail.InstanceSpec
  alias CleatDeploy.Hetzner.Client

  @server_payload %{
    "id" => 42,
    "name" => "gestaobem-cx33",
    "status" => "running",
    "public_net" => %{"ipv4" => %{"ip" => "203.0.113.10"}},
    "server_type" => %{
      "name" => "cx33",
      "description" => "CX33",
      "cores" => 4,
      "memory" => 8,
      "disk" => 80,
      "prices" => [
        %{
          "location" => "fsn1",
          "price_monthly" => %{"gross" => "7.5900"}
        }
      ]
    },
    "image" => %{"name" => "ubuntu-24.04", "description" => "Ubuntu 24.04 Standard"},
    "datacenter" => %{"location" => %{"name" => "fsn1"}}
  }

  test "map_server/1 maps Hetzner API payload onto InstanceSpec" do
    spec = Client.map_server(@server_payload)

    assert %InstanceSpec{} = spec
    assert spec.bundle_id == "cx33"
    assert spec.bundle_name == "CX33"
    assert spec.cpu_count == 4
    assert spec.ram_mb == 8192
    assert spec.disk_gb == 80
    assert spec.status == "running"
    assert spec.blueprint_name == "Ubuntu 24.04 Standard"
    assert Decimal.eq?(spec.monthly_price_usd, Decimal.new("7.59"))
  end

  test "public_ipv4/1 reads the primary IPv4" do
    assert Client.public_ipv4(@server_payload) == "203.0.113.10"
  end

  test "ssh_key_name/1 derives the uploaded key name from the key itself" do
    key = "ssh-ed25519 AAAA test@cleat"

    assert Client.ssh_key_name(key) == "paas-774afd795240af98"
    assert Client.ssh_key_name(key) == Client.ssh_key_name(key)
    refute Client.ssh_key_name(key) == Client.ssh_key_name(key <> "\n")
  end
end
