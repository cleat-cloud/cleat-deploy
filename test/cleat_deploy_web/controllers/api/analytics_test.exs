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
