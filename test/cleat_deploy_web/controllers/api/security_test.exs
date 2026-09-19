defmodule CleatDeployWeb.Api.SecurityTest do
  use CleatDeployWeb.ConnCase, async: false

  alias CleatDeploy.Accounts
  alias CleatDeploy.Accounts.TenantMembership
  alias CleatDeploy.AccountsFixtures
  alias CleatDeploy.Repo
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)

    {:ok, token, _api_token} =
      Accounts.create_api_token(scope.user, scope.tenant, %{name: "owner"})

    %{scope: scope, app: app, token: token}
  end

  test "password change invalidates the token", %{scope: scope, token: token} do
    {:ok, {_user, _expired}} =
      Accounts.update_user_password(scope.user, %{password: "brand new secret"})

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/me")
    assert json_response(conn, 401)["error"] == "invalid_or_revoked_token"
  end

  test "read endpoints are allowed for members, writes are forbidden", %{scope: scope, app: app} do
    member = AccountsFixtures.user_fixture()

    {:ok, _membership} =
      %TenantMembership{}
      |> TenantMembership.changeset(%{
        user_id: member.id,
        tenant_id: scope.tenant.id,
        role: "member"
      })
      |> Repo.insert()

    {:ok, token, _} = Accounts.create_api_token(member, scope.tenant, %{name: "member"})

    read = build_conn() |> auth(token) |> get(~p"/api/v1/apps")
    assert json_response(read, 200)

    deploy =
      build_conn()
      |> auth(token)
      |> json_post(~p"/api/v1/apps/#{app.id}/deployments", %{})

    assert json_response(deploy, 403)["error"] == "forbidden"

    env =
      build_conn()
      |> auth(token)
      |> json_put(~p"/api/v1/apps/#{app.id}/env", %{key: "X", value: "y"})

    assert json_response(env, 403)["error"] == "forbidden"
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp json_post(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp json_put(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put(path, Jason.encode!(body))
  end
end
