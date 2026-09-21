defmodule CleatDeployWeb.Api.AppsTest do
  use CleatDeployWeb.ConnCase, async: false

  alias CleatDeploy.Accounts
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)

    {:ok, token, _api_token} =
      Accounts.create_api_token(scope.user, scope.tenant, %{name: "apps"})

    %{scope: scope, server: server, app: app, token: token}
  end

  test "GET /api/v1/apps/:app_id/logs supports since and tail filters", %{
    token: token,
    app: app
  } do
    conn =
      build_conn()
      |> auth(token)
      |> get(~p"/api/v1/apps/#{app.id}/logs?since=1h&tail=50")

    data = json_response(conn, 200)["data"]

    assert is_list(data["lines"])
  end

  test "GET /api/v1/apps/:app_id/logs rejects an invalid since", %{token: token, app: app} do
    conn = build_conn() |> auth(token) |> get(~p"/api/v1/apps/#{app.id}/logs?since=nope")

    assert json_response(conn, 422)["error"] == "invalid_request"
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
end
