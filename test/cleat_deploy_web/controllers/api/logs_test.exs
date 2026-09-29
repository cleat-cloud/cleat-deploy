defmodule CleatDeployWeb.Api.LogsTest do
  use CleatDeployWeb.ConnCase, async: false

  alias CleatDeploy.Accounts
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Observability.LogEvent
  alias CleatDeploy.Repo
  alias CleatDeploy.TenancyFixtures
  alias CleatDeployWeb.Api.Contract

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    {:ok, token, _api_token} = Accounts.create_api_token(scope.user, scope.tenant, %{name: "ci"})

    insert_event(scope.tenant.id, app, server, %{severity: "err", message: "boom happened"})
    insert_event(scope.tenant.id, app, server, %{severity: "info", message: "all good"})

    %{scope: scope, server: server, app: app, token: token}
  end

  test "GET /api/v1/logs requires a token" do
    conn = get(build_conn(), ~p"/api/v1/logs")
    assert json_response(conn, 401)["error"] == "missing_bearer_token"
  end

  test "returns the tenant's events with the contracted keys", %{token: token, app: app} do
    conn =
      build_conn()
      |> auth(token)
      |> get(~p"/api/v1/logs?app=#{app.slug}&min_severity=err")

    data = json_response(conn, 200)["data"]

    assert [event] = data
    assert event["message"] == "boom happened"
    assert event["severity"] == "err"

    assert event |> Map.keys() |> Enum.sort() ==
             Contract.keys("log_event") |> Enum.sort()
  end

  test "filters by app slug, severity and text", %{token: token, app: app} do
    conn =
      build_conn()
      |> auth(token)
      |> get(~p"/api/v1/logs?app=#{app.slug}&severity=info&q=ALL")

    assert [event] = json_response(conn, 200)["data"]
    assert event["message"] == "all good"

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/logs?q=nothing-matches")
    assert json_response(conn, 200)["data"] == []
  end

  test "supports since windows and limit", %{token: token} do
    conn = build_conn() |> auth(token) |> get(~p"/api/v1/logs?since=1d")
    assert length(json_response(conn, 200)["data"]) == 2

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/logs?limit=1")
    assert length(json_response(conn, 200)["data"]) == 1
  end

  test "does not leak another tenant's events", %{token: token} do
    other_scope = TenancyFixtures.scope_fixture()
    other_server = TenancyFixtures.server_fixture(other_scope)
    other_app = TenancyFixtures.app_fixture(other_scope, other_server)

    insert_event(other_scope.tenant.id, other_app, other_server, %{message: "secret"})

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/logs?q=secret")
    assert json_response(conn, 200)["data"] == []
  end

  test "rejects invalid filters", %{token: token} do
    for query <- ["severity=nope", "min_severity=nope", "since=yesterday", "limit=0"] do
      conn = build_conn() |> auth(token) |> get("/api/v1/logs?" <> query)

      assert json_response(conn, 422)["error"] == "invalid_request",
             "expected #{query} to be rejected"
    end
  end

  test "404s on an unknown app", %{token: token} do
    conn = build_conn() |> auth(token) |> get(~p"/api/v1/logs?app=does-not-exist")
    assert json_response(conn, 404)["error"] == "not_found"
  end

  test "filters by environment", %{token: token, app: app, server: server, scope: scope} do
    insert_event(scope.tenant.id, app, server, %{environment: "develop", message: "on develop"})

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/logs?environment=develop")
    assert [%{"message" => "on develop"}] = json_response(conn, 200)["data"]
  end

  test "GET /api/v1/logs/groups clusters similar errors", %{
    token: token,
    app: app,
    server: server,
    scope: scope
  } do
    fp = CleatDeploy.Observability.Fingerprint.of("crash pid 1")

    insert_event(scope.tenant.id, app, server, %{
      severity: "err",
      message: "crash pid 1",
      fingerprint: fp
    })

    insert_event(scope.tenant.id, app, server, %{
      severity: "err",
      message: "crash pid 2",
      fingerprint: fp
    })

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/logs/groups?app=#{app.slug}")
    assert [group] = json_response(conn, 200)["data"]
    assert group["count"] == 2
    assert group["severity"] == "err"
    assert group["fingerprint"] == fp
  end

  defp insert_event(tenant_id, app, server, attrs) do
    defaults = %{
      tenant_id: tenant_id,
      app_id: app.id,
      server_id: server.id,
      source: "app",
      unit: app.systemd_unit || App.default_systemd_unit(app.slug, app.runtime || "phoenix"),
      cursor: "cursor-#{System.unique_integer([:positive])}",
      severity: "info",
      message: "hello",
      occurred_at: DateTime.utc_now(:second)
    }

    Repo.insert!(struct!(LogEvent, Map.merge(defaults, attrs)))
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
end
