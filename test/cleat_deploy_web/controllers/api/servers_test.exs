defmodule CleatDeployWeb.Api.ServersTest do
  use CleatDeployWeb.ConnCase, async: false

  import Mox

  alias CleatDeploy.AWS.Lightsail.InstanceSpec
  alias CleatDeploy.Accounts
  alias CleatDeploy.AWS.LightsailMock
  alias CleatDeploy.Hetzner.Catalog
  alias CleatDeploy.HetznerMock
  alias CleatDeploy.TenancyFixtures

  setup :verify_on_exit!

  setup do
    scope = TenancyFixtures.scope_fixture()
    {:ok, token, _} = Accounts.create_api_token(scope.user, scope.tenant, %{name: "srv"})
    %{scope: scope, token: token}
  end

  test "POST /api/v1/servers creates a server", %{token: token} do
    conn =
      build_conn()
      |> auth(token)
      |> json_post(~p"/api/v1/servers", %{
        name: "box-#{System.unique_integer([:positive])}",
        host_ip: "10.0.0.9",
        ssh_user: "ubuntu",
        region: "fsn1",
        provider: "hetzner"
      })

    data = json_response(conn, 201)["data"]
    assert data["host_ip"] == "10.0.0.9"
    assert data["provider"] == "hetzner"
  end

  test "DELETE /api/v1/servers/:id deletes a server", %{scope: scope, token: token} do
    server = TenancyFixtures.server_fixture(scope)

    assert build_conn()
           |> auth(token)
           |> delete(~p"/api/v1/servers/#{server.id}")
           |> response(204) == ""

    assert (build_conn()
            |> auth(token)
            |> delete(~p"/api/v1/servers/#{server.id}")
            |> json_response(404))["error"] == "not_found"
  end

  test "DELETE /api/v1/servers/:id refuses servers with apps", %{scope: scope, token: token} do
    server = TenancyFixtures.server_fixture(scope)
    _app = TenancyFixtures.app_fixture(scope, server)

    conn = build_conn() |> auth(token) |> delete(~p"/api/v1/servers/#{server.id}")
    assert json_response(conn, 409)["error"] == "server_has_apps"
  end

  test "POST /api/v1/servers/:id/sync refreshes specs", %{scope: scope, token: token} do
    server =
      TenancyFixtures.server_fixture(scope, %{
        aws_instance_name: "vm-#{System.unique_integer([:positive])}",
        region: "us-east-1"
      })

    spec = %InstanceSpec{
      bundle_id: "nano_3_0",
      bundle_name: "Nano",
      cpu_count: 2,
      ram_mb: 512,
      disk_gb: 20,
      status: "running",
      blueprint_name: "Ubuntu",
      monthly_price_usd: Decimal.new("5.00")
    }

    expect(LightsailMock, :get_instance, fn "us-east-1", name ->
      assert name == server.aws_instance_name
      {:ok, spec}
    end)

    conn = build_conn() |> auth(token) |> json_post(~p"/api/v1/servers/#{server.id}/sync", %{})
    data = json_response(conn, 200)["data"]

    assert data["bundle_name"] == "Nano"
    assert data["instance_status"] == "running"
  end

  test "POST /api/v1/servers/:id/stop powers the instance off", %{scope: scope, token: token} do
    server =
      TenancyFixtures.server_fixture(scope, %{aws_instance_name: "vm9", region: "us-east-1"})

    expect(LightsailMock, :power, fn "us-east-1", "vm9", :stop -> :ok end)

    expect(LightsailMock, :get_instance, fn "us-east-1", "vm9" ->
      {:ok, spec("stopped")}
    end)

    conn = build_conn() |> auth(token) |> json_post(~p"/api/v1/servers/#{server.id}/stop", %{})
    assert json_response(conn, 200)["data"]["instance_status"] == "stopped"
  end

  test "POST /api/v1/servers/:id/start powers the instance on", %{scope: scope, token: token} do
    server =
      TenancyFixtures.server_fixture(scope, %{aws_instance_name: "vm10", region: "us-east-1"})

    expect(LightsailMock, :power, fn "us-east-1", "vm10", :start -> :ok end)

    expect(LightsailMock, :get_instance, fn "us-east-1", "vm10" ->
      {:ok, spec("running")}
    end)

    conn = build_conn() |> auth(token) |> json_post(~p"/api/v1/servers/#{server.id}/start", %{})
    assert json_response(conn, 200)["data"]["instance_status"] == "running"
  end

  test "POST /api/v1/servers/provision creates a Hetzner VM", %{token: token} do
    spec = spec("running", "cx33", "203.0.113.7")
    name = "box-provision"

    expect(HetznerMock, :create_instance, fn attrs ->
      assert attrs.name == name
      {:ok, spec}
    end)

    conn =
      build_conn()
      |> auth(token)
      |> json_post(~p"/api/v1/servers/provision", %{
        name: name,
        region: "fsn1",
        bundle_id: "cx33",
        deploy_mode: "shared"
      })

    data = json_response(conn, 201)["data"]
    assert data["host_ip"] == "203.0.113.7"
    assert data["provider"] == "hetzner"
  end

  test "POST /api/v1/servers/provision rejects an invalid bundle", %{token: token} do
    conn =
      build_conn()
      |> auth(token)
      |> json_post(~p"/api/v1/servers/provision", %{
        name: "box-bad",
        region: "fsn1",
        bundle_id: "nope",
        deploy_mode: "shared"
      })

    assert json_response(conn, 422)["error"] == "invalid_request"
  end

  test "GET /api/v1/servers/:id/resize-options excludes the current bundle", %{
    scope: scope,
    token: token
  } do
    server =
      TenancyFixtures.server_fixture(scope, %{
        provider: "hetzner",
        region: "fsn1",
        bundle_id: "cx33"
      })

    expect(HetznerMock, :list_bundles, fn "fsn1" -> {:ok, Catalog.all_bundles()} end)

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/servers/#{server.id}/resize-options")
    ids = json_response(conn, 200)["data"] |> Enum.map(& &1["bundle_id"])

    assert "cx43" in ids
    refute "cx33" in ids
  end

  test "POST /api/v1/servers/:id/resize changes the bundle", %{scope: scope, token: token} do
    server =
      TenancyFixtures.server_fixture(scope, %{
        provider: "hetzner",
        region: "fsn1",
        aws_instance_name: "box9",
        bundle_id: "cx33"
      })

    expect(HetznerMock, :change_bundle, fn "fsn1", "box9", "cx43" -> :ok end)

    expect(HetznerMock, :get_instance, fn "fsn1", "box9" ->
      {:ok, spec("running", "cx43")}
    end)

    conn =
      build_conn()
      |> auth(token)
      |> json_post(~p"/api/v1/servers/#{server.id}/resize", %{bundle_id: "cx43"})

    assert json_response(conn, 200)["data"]["bundle_id"] == "cx43"
  end

  test "GET /api/v1/servers/:id/logs returns journal lines", %{scope: scope, token: token} do
    server = TenancyFixtures.server_fixture(scope)

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/servers/#{server.id}/logs")
    data = json_response(conn, 200)["data"]

    assert is_list(data["lines"])
    assert data["fetched_at"]
  end

  test "GET /api/v1/servers/:id/logs rejects a malicious unit", %{
    scope: scope,
    token: token
  } do
    server = TenancyFixtures.server_fixture(scope)

    conn =
      build_conn()
      |> auth(token)
      |> get(~p"/api/v1/servers/#{server.id}/logs?unit=evil;rm")

    assert json_response(conn, 422)["error"] == "invalid_request"
  end

  defp spec(status, bundle_id \\ "nano_3_0", public_ip \\ nil) do
    %InstanceSpec{
      bundle_id: bundle_id,
      bundle_name: "Nano",
      cpu_count: 2,
      ram_mb: 512,
      disk_gb: 20,
      status: status,
      blueprint_name: "Ubuntu",
      monthly_price_usd: Decimal.new("5.00"),
      public_ip: public_ip
    }
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp json_post(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end
end
