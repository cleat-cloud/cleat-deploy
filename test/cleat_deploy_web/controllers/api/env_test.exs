defmodule CleatDeployWeb.Api.EnvTest do
  use CleatDeployWeb.ConnCase, async: false

  alias CleatDeploy.Accounts
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    {:ok, token, _api_token} = Accounts.create_api_token(scope.user, scope.tenant, %{name: "ci"})

    %{scope: scope, app: app, token: token}
  end

  test "PUT /apps/:app/env stores a key and lists it", %{token: token, app: app} do
    conn =
      build_conn()
      |> auth(token)
      |> json_put(~p"/api/v1/apps/#{app.slug}/env", %{key: "DATABASE_URL", value: "postgres://x"})

    data = json_response(conn, 200)["data"]
    assert Enum.any?(data, &(&1["key"] == "DATABASE_URL" and &1["value"] == "postgres://x"))
  end

  test "sensitive values are masked unless reveal=true", %{token: token, app: app} do
    build_conn()
    |> auth(token)
    |> json_put(~p"/api/v1/apps/#{app.id}/env", %{
      key: "SECRET_KEY_BASE",
      value: "supersecretvalue"
    })
    |> json_response(200)

    masked =
      build_conn() |> auth(token) |> get(~p"/api/v1/apps/#{app.id}/env") |> json_response(200)

    entry = Enum.find(masked["data"], &(&1["key"] == "SECRET_KEY_BASE"))
    assert entry["sensitive"] == true
    assert entry["revealed"] == false
    refute entry["value"] =~ "supersecretvalue"

    revealed =
      build_conn()
      |> auth(token)
      |> get(~p"/api/v1/apps/#{app.id}/env?reveal=true")
      |> json_response(200)

    entry = Enum.find(revealed["data"], &(&1["key"] == "SECRET_KEY_BASE"))
    assert entry["value"] == "supersecretvalue"
    assert entry["revealed"] == true
  end

  test "PUT with a vars map upserts several keys", %{token: token, app: app} do
    conn =
      build_conn()
      |> auth(token)
      |> json_put(~p"/api/v1/apps/#{app.id}/env", %{vars: %{"FOO" => "1", "BAR" => "2"}})

    data = json_response(conn, 200)["data"]
    assert Enum.any?(data, &(&1["key"] == "FOO" and &1["value"] == "1"))
    assert Enum.any?(data, &(&1["key"] == "BAR" and &1["value"] == "2"))
  end

  test "invalid keys are rejected without partial writes", %{token: token, app: app} do
    conn =
      build_conn()
      |> auth(token)
      |> json_put(~p"/api/v1/apps/#{app.id}/env", %{
        vars: %{"GOOD_KEY" => "ok", "bad-key" => "nope"}
      })

    assert json_response(conn, 422)["error"] == "invalid_request"

    listed =
      build_conn() |> auth(token) |> get(~p"/api/v1/apps/#{app.id}/env") |> json_response(200)

    refute Enum.any?(listed["data"], &(&1["key"] == "GOOD_KEY"))
  end

  test "DELETE removes a key, 404 when missing", %{token: token, app: app} do
    build_conn()
    |> auth(token)
    |> json_put(~p"/api/v1/apps/#{app.id}/env", %{key: "OLD_KEY", value: "x"})
    |> json_response(200)

    assert build_conn()
           |> auth(token)
           |> delete(~p"/api/v1/apps/#{app.id}/env/OLD_KEY")
           |> response(204) == ""

    assert (build_conn()
            |> auth(token)
            |> delete(~p"/api/v1/apps/#{app.id}/env/OLD_KEY")
            |> json_response(404))["error"] == "not_found"
  end

  test "cannot touch another tenant's env", %{token: token} do
    other = TenancyFixtures.scope_fixture()
    other_server = TenancyFixtures.server_fixture(other)
    other_app = TenancyFixtures.app_fixture(other, other_server)

    conn =
      build_conn()
      |> auth(token)
      |> json_put(~p"/api/v1/apps/#{other_app.id}/env", %{key: "X", value: "y"})

    assert json_response(conn, 404)["error"] == "not_found"
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp json_put(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put(path, Jason.encode!(body))
  end
end
