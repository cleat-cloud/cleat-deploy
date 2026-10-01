defmodule CleatDeployWeb.Internal.DomainAskTest do
  use CleatDeployWeb.ConnCase, async: false

  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        host: "loja.gestaobem.com",
        slug: "catalogo-#{System.unique_integer([:positive])}"
      })

    %{app: app, server: server, scope: scope}
  end

  test "returns 200 when the domain is a registered app host", %{conn: conn} do
    conn = get(conn, "/internal/domains/ask", %{"domain" => "loja.gestaobem.com"})
    assert conn.status == 200
  end

  test "returns 200 for one alias of a compound app host", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    TenancyFixtures.app_fixture(scope, server, %{
      host: "plaza.purplestock.com.br, www.plaza.purplestock.com.br, plaza.apps.gestaobem.com",
      slug: "plaza-#{System.unique_integer([:positive])}"
    })

    conn = get(conn, "/internal/domains/ask", %{"domain" => "plaza.apps.gestaobem.com"})
    assert conn.status == 200
  end

  test "returns 404 when the domain is not registered", %{conn: conn} do
    conn = get(conn, "/internal/domains/ask", %{"domain" => "unknown.example.com"})
    assert conn.status == 404
  end

  test "returns 400 when domain is missing", %{conn: conn} do
    conn = get(conn, "/internal/domains/ask")
    assert conn.status == 400
  end

  test "returns 403 from a non-loopback client", %{conn: conn} do
    conn =
      conn
      |> Map.put(:remote_ip, {203, 0, 113, 9})
      |> get("/internal/domains/ask", %{"domain" => "loja.gestaobem.com"})

    assert conn.status == 403
  end

  test "returns 200 from IPv4-mapped IPv6 loopback (Bandit dual-stack)", %{conn: conn} do
    conn =
      conn
      |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 65535, 32512, 1})
      |> get("/internal/domains/ask", %{"domain" => "loja.gestaobem.com"})

    assert conn.status == 200
  end

  test "returns 403 from IPv4-mapped IPv6 of a public address", %{conn: conn} do
    conn =
      conn
      |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 65535, 51968, 28937})
      |> get("/internal/domains/ask", %{"domain" => "loja.gestaobem.com"})

    assert conn.status == 403
  end

  test "Hetzner Caddyfile asks the panel on 4010, not catalogo on 4000" do
    text = File.read!("deploy/Caddyfile.hetzner")
    assert text =~ "ask http://127.0.0.1:4010/internal/domains/ask"
    refute text =~ "ask http://127.0.0.1:4000/internal/domains/ask"
  end
end
