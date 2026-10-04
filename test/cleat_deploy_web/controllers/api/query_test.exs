defmodule CleatDeployWeb.Api.QueryTest do
  use CleatDeployWeb.ConnCase, async: false

  import Mox

  alias CleatDeploy.Accounts
  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.QueryMock
  alias CleatDeploy.TenancyFixtures
  alias CleatDeployWeb.Api.Contract

  setup :verify_on_exit!

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    {:ok, token, _api_token} = Accounts.create_api_token(scope.user, scope.tenant, %{name: "ci"})

    %{scope: scope, server: server, app: app, token: token}
  end

  test "POST /api/v1/apps/:id/query runs a read-only SELECT", %{
    token: token,
    app: app,
    scope: scope
  } do
    {:ok, _} = Apps.put_env_var(app, "DATABASE_PATH", "/opt/apps/demo/data.db")
    app = Apps.get_app!(scope, app.id)

    expect(QueryMock, :run, fn received, ["bash", "-lc", script] ->
      assert received.id == app.id
      assert script =~ "sqlite3"
      {:ok, "id,email\n1,ada@example.com\n"}
    end)

    conn =
      build_conn()
      |> auth(token)
      |> json_post(~p"/api/v1/apps/#{app.slug}/query", %{
        sql: "SELECT id, email FROM users",
        limit: 20
      })

    data = json_response(conn, 200)["data"]
    assert data["slug"] == app.slug
    assert data["engine"] == "sqlite"
    assert data["columns"] == ["id", "email"]
    assert data["rows"] == [["1", "ada@example.com"]]
    refute data["truncated"]
    assert data |> Map.keys() |> Enum.sort() == Contract.keys("app_query") |> Enum.sort()
  end

  test "rejects writes", %{token: token, app: app} do
    conn =
      build_conn()
      |> auth(token)
      |> json_post(~p"/api/v1/apps/#{app.id}/query", %{sql: "DELETE FROM users"})

    body = json_response(conn, 422)
    assert body["error"] == "invalid_sql"
    assert body["message"] =~ "read-only"
  end

  test "returns no_database when the app has no local store", %{token: token, app: app} do
    conn =
      build_conn()
      |> auth(token)
      |> json_post(~p"/api/v1/apps/#{app.id}/query", %{sql: "SELECT 1"})

    assert json_response(conn, 422)["error"] == "no_database"
  end

  test "does not query another tenant", %{token: token} do
    other = TenancyFixtures.scope_fixture()
    other_server = TenancyFixtures.server_fixture(other)
    other_app = TenancyFixtures.app_fixture(other, other_server)

    conn =
      build_conn()
      |> auth(token)
      |> json_post(~p"/api/v1/apps/#{other_app.slug}/query", %{sql: "SELECT 1"})

    assert json_response(conn, 404)["error"] == "not_found"
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp json_post(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end
end
