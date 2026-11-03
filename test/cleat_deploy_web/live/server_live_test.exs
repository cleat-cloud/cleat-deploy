defmodule CleatDeployWeb.ServerLiveTest do
  use CleatDeployWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias CleatDeploy.AWS.LightsailMock
  alias CleatDeploy.HetznerMock
  alias CleatDeploy.Servers
  alias CleatDeploy.TenancyFixtures

  setup :verify_on_exit!
  setup :register_and_log_in_user

  test "lists servers", %{conn: conn, scope: scope} do
    TenancyFixtures.server_fixture(scope, %{name: "lightsail-1", host_ip: "100.59.80.29"})

    {:ok, view, _html} = live(conn, ~p"/servers")
    assert has_element?(view, "#servers-list")
    assert render(view) =~ "lightsail-1"
  end

  test "creates a Hetzner VM from the new server form", %{conn: conn, scope: scope} do
    {:ok, keys} = CleatDeploy.Servers.SshKeys.generate()

    TenancyFixtures.server_fixture(scope, %{
      name: "seed-key",
      ssh_private_key: keys.private
    })

    expect(HetznerMock, :create_instance, fn attrs ->
      assert attrs.name == "prod-box"

      {:ok,
       %CleatDeploy.AWS.Lightsail.InstanceSpec{
         bundle_id: "cx33",
         bundle_name: "CX33",
         cpu_count: 4,
         ram_mb: 8192,
         disk_gb: 80,
         status: "running",
         blueprint_name: "Ubuntu 24.04",
         monthly_price_usd: Decimal.new("7.59"),
         name: "prod-box",
         public_ip: "167.233.201.55",
         region: "fsn1"
       }}
    end)

    {:ok, view, html} = live(conn, ~p"/servers/new")
    assert html =~ "Create VM"
    assert has_element?(view, "#create-server-form")

    assert view
           |> form("#create-server-form",
             server: %{name: "prod-box", region: "fsn1", bundle_id: "cx33", deploy_mode: "shared"}
           )
           |> render_submit()

    assert_redirect(view, ~p"/servers")

    assert Enum.any?(
             Servers.list_servers(scope),
             &(&1.name == "prod-box" and &1.host_ip == "167.233.201.55")
           )
  end

  test "lets the user switch Hetzner plan prices between euro and dollar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/servers/new")

    assert has_element?(view, "#plan-currency-eur")
    assert has_element?(view, "#plan-currency-usd")
    assert has_element?(view, "#bundle-cx33-price", "€7.59/mo")
    refute has_element?(view, "#bundle-cx33-price", "$8.80/mo")

    view
    |> element("#plan-currency-usd")
    |> render_click()

    assert has_element?(view, "#bundle-cx22-price", "$5.32/mo")
    assert has_element?(view, "#bundle-cx33-price", "$8.80/mo")
    refute has_element?(view, "#bundle-cx33-price", "€7.59/mo")

    view
    |> element("#plan-currency-eur")
    |> render_click()

    assert has_element?(view, "#bundle-cx33-price", "€7.59/mo")
    refute has_element?(view, "#bundle-cx33-price", "$8.80/mo")
  end

  test "registers an existing server from the fallback form", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/servers/new")

    view
    |> element("#form-mode-register")
    |> render_click()

    assert has_element?(view, "#server-form")

    assert view
           |> form("#server-form",
             server: %{name: "prod", host_ip: "10.0.0.1", region: "us-east-1"}
           )
           |> render_submit()

    assert_redirect(view, ~p"/servers")

    assert Enum.any?(
             Servers.list_servers(scope),
             &(&1.name == "prod" and &1.host_ip == "10.0.0.1")
           )
  end

  test "check cloud marks gone Lightsail VMs missing and can remove them", %{
    conn: conn,
    scope: scope
  } do
    server =
      TenancyFixtures.server_fixture(scope, %{
        name: "catalogo-lightsail",
        aws_instance_name: "catalogo-lightsail",
        host_ip: "52.73.89.19",
        provider: "lightsail",
        region: "us-east-1"
      })

    expect(LightsailMock, :list_instances, fn "us-east-1" -> {:ok, []} end)
    expect(HetznerMock, :list_instances, fn "fsn1" -> {:ok, []} end)

    {:ok, view, _html} = live(conn, ~p"/servers")
    assert has_element?(view, "#sync-cloud-button")

    html = render_click(view, "sync_cloud", %{})
    assert html =~ "missing"
    assert has_element?(view, "#remove-server-#{server.id}")
    refute has_element?(view, "#remove-confirm-modal")

    view
    |> element("#remove-server-#{server.id}")
    |> render_click()

    assert has_element?(view, "#remove-confirm-modal")
    assert render(view) =~ "Remove this server?"
    assert [%{id: id}] = Servers.list_servers(scope)
    assert id == server.id

    view
    |> element("#cancel-remove-server")
    |> render_click()

    refute has_element?(view, "#remove-confirm-modal")
    assert Servers.list_servers(scope) != []

    view
    |> element("#remove-server-#{server.id}")
    |> render_click()

    view
    |> element("#confirm-remove-server")
    |> render_click()

    assert Servers.list_servers(scope) == []
  end

  test "private Tailscale leftover with no apps can be removed from the panel", %{
    conn: conn,
    scope: scope
  } do
    server =
      TenancyFixtures.server_fixture(scope, %{
        name: "trip-lightsail",
        aws_instance_name: "trip-lightsail",
        host_ip: "100.59.80.29",
        provider: "lightsail",
        region: "us-east-1",
        instance_status: "private"
      })

    {:ok, view, _html} = live(conn, ~p"/servers")
    assert render(view) =~ "trip-lightsail"
    assert has_element?(view, "#remove-server-#{server.id}")

    view
    |> element("#remove-server-#{server.id}")
    |> render_click()

    view
    |> element("#confirm-remove-server")
    |> render_click()

    refute has_element?(view, "#servers-#{server.id}")
    refute has_element?(view, "#remove-server-#{server.id}")
    assert Servers.list_servers(scope) == []
  end
end
