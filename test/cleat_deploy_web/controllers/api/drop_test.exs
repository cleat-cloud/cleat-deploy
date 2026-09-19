defmodule CleatDeployWeb.Api.DropTest do
  use CleatDeployWeb.ConnCase, async: false

  alias CleatDeploy.Accounts
  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.Repo
  alias CleatDeploy.TenancyFixtures

  setup do
    dir = Path.join(System.tmp_dir!(), "cleat_drops_test_#{System.unique_integer([:positive])}")
    System.put_env("CLEAT_DROPS_DIR", dir)

    on_exit(fn ->
      System.delete_env("CLEAT_DROPS_DIR")
      System.delete_env("CLEAT_DROP_MAX_BYTES")
      File.rm_rf(dir)
    end)

    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    static = TenancyFixtures.app_fixture(scope, server, %{runtime: "static", github_repo: nil})
    phoenix = TenancyFixtures.app_fixture(scope, server)
    {:ok, token, _} = Accounts.create_api_token(scope.user, scope.tenant, %{name: "drop"})

    %{scope: scope, server: server, static: static, phoenix: phoenix, token: token, dir: dir}
  end

  test "stores the uploaded tarball and enqueues a drop deploy", %{
    static: app,
    token: token,
    dir: dir
  } do
    body = "fake-tarball-bytes-" <> String.duplicate("x", 32)

    conn = build_conn() |> auth(token) |> post_drop(app, body)
    data = json_response(conn, 201)["data"]

    assert data["status"] == "queued"
    assert_enqueued(worker: CleatDeploy.Workers.DeployWorker)

    deployment = Repo.get!(Deployment, data["id"])
    assert deployment.source == "drop"
    assert deployment.artifact_path =~ dir
    assert File.read!(deployment.artifact_path) == body
  end

  test "rejects drops for non-static apps", %{phoenix: app, token: token} do
    conn = build_conn() |> auth(token) |> post_drop(app, "fake")
    assert json_response(conn, 422)["error"] == "drops_require_static_runtime"
  end

  test "enforces the size limit", %{static: app, token: token} do
    System.put_env("CLEAT_DROP_MAX_BYTES", "10")

    conn = build_conn() |> auth(token) |> post_drop(app, String.duplicate("x", 64))
    body = json_response(conn, 413)

    assert body["error"] == "drop_too_large"
    assert body["max_bytes"] == 10
  end

  test "cannot drop to another tenant's app", %{token: token} do
    other = TenancyFixtures.scope_fixture()
    other_server = TenancyFixtures.server_fixture(other)

    other_app =
      TenancyFixtures.app_fixture(other, other_server, %{runtime: "static", github_repo: nil})

    conn = build_conn() |> auth(token) |> post_drop(other_app, "fake")
    assert json_response(conn, 404)["error"] == "not_found"
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp post_drop(conn, app, body) do
    conn
    |> put_req_header("content-type", "application/gzip")
    |> post(~p"/api/v1/apps/#{app.id}/drops", body)
  end
end
