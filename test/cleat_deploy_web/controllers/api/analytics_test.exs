defmodule CleatDeployWeb.Api.AnalyticsTest do
  use CleatDeployWeb.ConnCase, async: false

  alias CleatDeploy.Accounts
  alias CleatDeploy.TenancyFixtures
  alias CleatDeployWeb.Api.Contract

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    {:ok, token, _api_token} = Accounts.create_api_token(scope.user, scope.tenant, %{name: "ci"})

    %{scope: scope, server: server, token: token}
  end

  describe "GET /api/v1/analytics/requested" do
    test "requires a token" do
      conn = get(build_conn(), ~p"/api/v1/analytics/requested")
      assert json_response(conn, 401)["error"] == "missing_bearer_token"
    end

    test "ranks the tenant's apps from the access log with contracted keys", ctx do
      nfe =
        TenancyFixtures.app_fixture(ctx.scope, ctx.server, %{
          name: "NFe Fácil",
          slug: "nfe-facil",
          host: "nfe.gestaobem.com"
        })

      TenancyFixtures.app_fixture(ctx.scope, ctx.server, %{
        name: "Idle",
        slug: "idle-app",
        host: "idle.example.com"
      })

      stub_access_log(
        List.duplicate(
          Jason.encode!(%{ts: System.os_time(:second), request: %{host: "nfe.gestaobem.com"}}),
          3
        )
      )

      conn = build_conn() |> auth(ctx.token) |> get(~p"/api/v1/analytics/requested")
      data = json_response(conn, 200)["data"]

      assert [row] = data
      assert row["app_id"] == nfe.id
      assert row["slug"] == "nfe-facil"
      assert row["host"] == "nfe.gestaobem.com"
      assert row["requests"] == 3

      assert row |> Map.keys() |> Enum.sort() ==
               Contract.keys("analytics_requested") |> Enum.sort()
    end

    test "does not leak another tenant's traffic", ctx do
      other = TenancyFixtures.scope_fixture()
      other_server = TenancyFixtures.server_fixture(other)

      TenancyFixtures.app_fixture(other, other_server, %{
        name: "Secret",
        slug: "secret",
        host: "secret.example.com"
      })

      stub_access_log([
        Jason.encode!(%{ts: System.os_time(:second), request: %{host: "secret.example.com"}})
      ])

      conn = build_conn() |> auth(ctx.token) |> get(~p"/api/v1/analytics/requested")

      assert json_response(conn, 200)["data"] == []
    end

    test "an app without hits is not invented and a missing log returns []", ctx do
      TenancyFixtures.app_fixture(ctx.scope, ctx.server, %{
        name: "Quiet",
        slug: "quiet",
        host: "quiet.example.com"
      })

      stub_access_log([])

      conn = build_conn() |> auth(ctx.token) |> get(~p"/api/v1/analytics/requested")
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "GET /api/v1/analytics/visited" do
    test "ranks the tenant's apps by pageviews with contracted keys", ctx do
      app =
        TenancyFixtures.app_fixture(ctx.scope, ctx.server, %{
          name: "Fagulha",
          slug: "fagulha-app",
          host: "fagulha.apps.gestaobem.com"
        })

      stub_visited([
        %{slug: "fagulha-app", host: "fagulha.apps.gestaobem.com", pageviews: 12}
      ])

      conn = build_conn() |> auth(ctx.token) |> get(~p"/api/v1/analytics/visited")
      body = json_response(conn, 200)

      assert [row] = body["data"]
      assert row["app_id"] == app.id
      assert row["slug"] == "fagulha-app"
      assert row["host"] == "fagulha.apps.gestaobem.com"
      assert row["pageviews"] == 12
      assert body["stale"] == false

      assert row |> Map.keys() |> Enum.sort() ==
               Contract.keys("analytics_visited") |> Enum.sort()
    end

    test "surfaces stale when the sidecar is down", ctx do
      TenancyFixtures.app_fixture(ctx.scope, ctx.server, %{
        slug: "fagulha-app",
        host: "fagulha.apps.gestaobem.com"
      })

      stub_visited([], stale: true)

      conn = build_conn() |> auth(ctx.token) |> get(~p"/api/v1/analytics/visited")
      body = json_response(conn, 200)

      assert body["data"] == []
      assert body["stale"] == true
    end

    test "does not invent volume and does not leak other tenants", ctx do
      other = TenancyFixtures.scope_fixture()
      other_server = TenancyFixtures.server_fixture(other)

      TenancyFixtures.app_fixture(other, other_server, %{
        slug: "secret",
        host: "secret.example.com"
      })

      stub_visited([%{slug: "secret", host: "secret.example.com", pageviews: 9}])

      conn = build_conn() |> auth(ctx.token) |> get(~p"/api/v1/analytics/visited")
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "GET /api/v1/apps/:app_id/analytics" do
    test "returns the app summary for the requested range", ctx do
      app =
        TenancyFixtures.app_fixture(ctx.scope, ctx.server, %{
          slug: "fagulha-app",
          host: "fagulha.apps.gestaobem.com"
        })

      stub_app_summary(%{
        pageviews: 42,
        uniques: 7,
        series: [%{t: "2026-10-04T00:00:00Z", pageviews: 42}],
        paths: [%{path: "/", pageviews: 30}],
        referrers: [%{referrer: "google.com", pageviews: 4}],
        utm: [%{source: "news", medium: "email", campaign: "launch", pageviews: 2}],
        stale: false
      })

      conn =
        build_conn()
        |> auth(ctx.token)
        |> get(~p"/api/v1/apps/#{app.slug}/analytics?range=7d")

      data = json_response(conn, 200)["data"]

      assert data["app_id"] == app.id
      assert data["slug"] == "fagulha-app"
      assert data["range"] == "7d"
      assert data["pageviews"] == 42
      assert data["uniques"] == 7
      assert [%{"path" => "/", "pageviews" => 30}] = data["paths"]
      assert [%{"source" => "news"} = utm] = data["utm"]
      assert utm["campaign"] == "launch"
      assert data["stale"] == false

      assert data |> Map.keys() |> Enum.sort() ==
               Contract.keys("analytics_summary") |> Enum.sort()
    end

    test "an invalid range falls back to 24h", ctx do
      app = TenancyFixtures.app_fixture(ctx.scope, ctx.server)

      conn =
        build_conn()
        |> auth(ctx.token)
        |> get(~p"/api/v1/apps/#{app.id}/analytics?range=forever")

      assert json_response(conn, 200)["data"]["range"] == "24h"
    end

    test "sidecar down returns an empty summary flagged as stale", ctx do
      app = TenancyFixtures.app_fixture(ctx.scope, ctx.server)

      stub_app_summary(:fail)

      conn = build_conn() |> auth(ctx.token) |> get(~p"/api/v1/apps/#{app.id}/analytics")
      data = json_response(conn, 200)["data"]

      assert data["pageviews"] == 0
      assert data["stale"] == true
    end

    test "404s for an unknown or another tenant's app", ctx do
      conn = build_conn() |> auth(ctx.token) |> get(~p"/api/v1/apps/nope/analytics")
      assert json_response(conn, 404)["error"] == "not_found"

      other = TenancyFixtures.scope_fixture()
      other_server = TenancyFixtures.server_fixture(other)
      other_app = TenancyFixtures.app_fixture(other, other_server)

      conn = build_conn() |> auth(ctx.token) |> get(~p"/api/v1/apps/#{other_app.id}/analytics")
      assert json_response(conn, 404)["error"] == "not_found"
    end
  end

  defp stub_visited(rows, opts \\ []) do
    Application.put_env(:cleat_deploy, :analytics_visited_stub, rows)
    Application.put_env(:cleat_deploy, :analytics_visited_stale, opts[:stale] == true)

    on_exit(fn ->
      Application.delete_env(:cleat_deploy, :analytics_visited_stub)
      Application.delete_env(:cleat_deploy, :analytics_visited_stale)
    end)
  end

  defp stub_app_summary(:fail) do
    Application.put_env(:cleat_deploy, :analytics_app_fail, true)

    on_exit(fn -> Application.delete_env(:cleat_deploy, :analytics_app_fail) end)
  end

  defp stub_app_summary(summary) do
    Application.put_env(:cleat_deploy, :analytics_app_stub, summary)

    on_exit(fn -> Application.delete_env(:cleat_deploy, :analytics_app_stub) end)
  end

  defp stub_access_log(lines) do
    path = Path.join(System.tmp_dir!(), "cleat-access-#{System.unique_integer([:positive])}.log")
    File.write!(path, Enum.join(lines, "\n") <> "\n")

    previous = Application.get_env(:cleat_deploy, :caddy_access_log_path)
    Application.put_env(:cleat_deploy, :caddy_access_log_path, path)

    on_exit(fn ->
      File.rm(path)

      if previous do
        Application.put_env(:cleat_deploy, :caddy_access_log_path, previous)
      else
        Application.delete_env(:cleat_deploy, :caddy_access_log_path)
      end
    end)
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
end
