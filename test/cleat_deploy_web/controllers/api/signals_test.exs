defmodule CleatDeployWeb.Api.SignalsTest do
  use CleatDeployWeb.ConnCase, async: false

  alias CleatDeploy.Accounts
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.Observability.LogEvent
  alias CleatDeploy.Repo
  alias CleatDeploy.Signals
  alias CleatDeploy.TenancyFixtures
  alias CleatDeployWeb.Api.Contract

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    {:ok, token, _api_token} = Accounts.create_api_token(scope.user, scope.tenant, %{name: "ci"})

    %{scope: scope, server: server, app: app, token: token}
  end

  test "GET /api/v1/signals/health requires a token" do
    conn = get(build_conn(), ~p"/api/v1/signals/health")
    assert json_response(conn, 401)["error"] == "missing_bearer_token"
  end

  test "returns the tenant health overview with contracted keys", %{
    token: token,
    app: app,
    scope: scope,
    server: server
  } do
    now = DateTime.utc_now(:second)

    for _ <- 1..6 do
      insert_event(scope.tenant.id, app, server, %{
        severity: "err",
        occurred_at: DateTime.add(now, -30, :second)
      })
    end

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/signals/health")
    data = json_response(conn, 200)["data"]
    row = Enum.find(data, &(&1["slug"] == app.slug))

    assert row["status"] == "degraded"
    assert "error_rate" in row["reasons"]
    assert row["error_count"] == 6

    assert row |> Map.keys() |> Enum.sort() ==
             Contract.keys("signal_health") |> Enum.sort()
  end

  test "filters health by app slug", %{token: token, app: app} do
    conn = build_conn() |> auth(token) |> get(~p"/api/v1/signals/health?app=#{app.slug}")
    data = json_response(conn, 200)["data"]

    assert Enum.all?(data, &(&1["slug"] == app.slug))
  end

  test "404s health for an unknown app", %{token: token} do
    conn = build_conn() |> auth(token) |> get(~p"/api/v1/signals/health?app=does-not-exist")
    assert json_response(conn, 404)["error"] == "not_found"
  end

  test "does not leak another tenant's health", %{token: token} do
    other = TenancyFixtures.scope_fixture()
    other_server = TenancyFixtures.server_fixture(other)
    other_app = TenancyFixtures.app_fixture(other, other_server)
    now = DateTime.utc_now(:second)

    for _ <- 1..6 do
      insert_event(other.tenant.id, other_app, other_server, %{
        severity: "err",
        occurred_at: DateTime.add(now, -30, :second)
      })
    end

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/signals/health")
    slugs = json_response(conn, 200)["data"] |> Enum.map(& &1["slug"])
    refute other_app.slug in slugs
  end

  test "GET /api/v1/signals/metrics requires an app", %{token: token} do
    conn = build_conn() |> auth(token) |> get(~p"/api/v1/signals/metrics")
    assert json_response(conn, 404)["error"] == "not_found"
  end

  test "returns RED metrics, series and deploy markers", %{
    token: token,
    app: app,
    scope: scope,
    server: server
  } do
    now = DateTime.utc_now(:second)

    insert_deploy(app,
      git_sha: "cafebabe",
      finished_at: DateTime.add(now, -600, :second)
    )

    for _ <- 1..3 do
      insert_event(scope.tenant.id, app, server, %{
        severity: "err",
        occurred_at: DateTime.add(now, -120, :second)
      })
    end

    conn =
      build_conn()
      |> auth(token)
      |> get(~p"/api/v1/signals/metrics?app=#{app.slug}&range=1h")

    data = json_response(conn, 200)["data"]

    assert data["slug"] == app.slug
    assert data["range"] == "1h"
    assert data["red"]["errors"] == 3
    assert data["red"]["logs"] == 3
    assert data["host"]["cpu"] == nil
    assert [%{"git_sha" => "cafebabe"}] = data["deploy_markers"]

    assert data |> Map.keys() |> Enum.sort() ==
             Contract.keys("signal_metrics") |> Enum.sort()
  end

  test "lists firing alerts and acks them", %{
    token: token,
    app: app,
    scope: scope,
    server: server
  } do
    now = DateTime.utc_now(:second)

    for _ <- 1..6 do
      insert_event(scope.tenant.id, app, server, %{
        severity: "err",
        occurred_at: DateTime.add(now, -30, :second)
      })
    end

    {:ok, [alert]} = Signals.evaluate_alerts(scope, now: now)

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/signals/alerts")
    [open] = json_response(conn, 200)["data"]
    assert open["id"] == alert.id
    assert open["slug"] == app.slug
    assert open["rule"] == "error_rate"
    assert open["status"] == "firing"

    assert open |> Map.keys() |> Enum.sort() ==
             Contract.keys("signal_alert") |> Enum.sort()

    conn =
      build_conn()
      |> auth(token)
      |> post(~p"/api/v1/signals/alerts/#{alert.id}/ack")

    acked = json_response(conn, 200)["data"]
    assert acked["status"] == "acked"

    conn =
      build_conn()
      |> auth(token)
      |> post(~p"/api/v1/signals/alerts/#{alert.id}/ack")

    assert json_response(conn, 422)["error"] == "invalid_request"
  end

  test "404s ack for an unknown alert", %{token: token} do
    conn = build_conn() |> auth(token) |> post(~p"/api/v1/signals/alerts/nope/ack")
    assert json_response(conn, 404)["error"] == "not_found"
  end

  test "returns the incident timeline for an app", %{
    token: token,
    app: app,
    scope: scope,
    server: server
  } do
    now = DateTime.utc_now(:second)
    fp = CleatDeploy.Observability.Fingerprint.of("crash in worker")

    insert_deploy(app,
      git_sha: "feedface",
      finished_at: DateTime.add(now, -600, :second)
    )

    for _ <- 1..6 do
      insert_event(scope.tenant.id, app, server, %{
        severity: "err",
        message: "crash in worker",
        fingerprint: fp,
        occurred_at: DateTime.add(now, -30, :second)
      })
    end

    {:ok, _} = Signals.evaluate_alerts(scope, now: now)

    conn =
      build_conn()
      |> auth(token)
      |> get(~p"/api/v1/signals/incidents?app=#{app.slug}&range=24h")

    data = json_response(conn, 200)["data"]
    kinds = Enum.map(data["events"], & &1["kind"])

    assert data["slug"] == app.slug
    assert "deploy" in kinds
    assert "alert" in kinds
    assert "error_group" in kinds

    assert data |> Map.keys() |> Enum.sort() ==
             Contract.keys("signal_incident") |> Enum.sort()
  end

  test "GET /api/v1/signals/incidents requires an app", %{token: token} do
    conn = build_conn() |> auth(token) |> get(~p"/api/v1/signals/incidents")
    assert json_response(conn, 404)["error"] == "not_found"
  end

  defp insert_deploy(app, attrs) do
    Repo.insert!(%Deployment{
      app_id: app.id,
      git_sha: attrs[:git_sha],
      git_ref: attrs[:git_ref] || "main",
      status: attrs[:status] || :success,
      finished_at: attrs[:finished_at],
      started_at: attrs[:finished_at]
    })
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
