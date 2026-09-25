defmodule CleatDeployWeb.Api.ApiTest do
  use CleatDeployWeb.ConnCase, async: false

  import Mox

  alias CleatDeploy.Accounts
  alias CleatDeploy.Apps.RuntimeLogsMock
  alias CleatDeploy.Deployments
  alias CleatDeploy.RuntimeLogsFixtures
  alias CleatDeploy.TenancyFixtures

  setup :verify_on_exit!

  setup do
    RuntimeLogsFixtures.stub_success()

    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    {:ok, token, _api_token} = Accounts.create_api_token(scope.user, scope.tenant, %{name: "ci"})

    %{scope: scope, server: server, app: app, token: token}
  end

  test "POST /api/v1/auth/tokens issues a token", %{scope: scope} do
    conn =
      json_post(build_conn(), ~p"/api/v1/auth/tokens", %{
        email: scope.user.email,
        password: "hello world!"
      })

    body = json_response(conn, 201)
    assert String.starts_with?(body["token"], "cleat_")
    assert body["tenant"]["id"] == scope.tenant.id
    assert body["user"]["email"] == scope.user.email

    assert body |> Map.keys() |> Enum.sort() ==
             CleatDeployWeb.Api.Contract.keys("token") |> Enum.sort()
  end

  test "POST /api/v1/auth/tokens rejects bad credentials" do
    conn =
      json_post(build_conn(), ~p"/api/v1/auth/tokens", %{
        email: "nobody@example.com",
        password: "wrong"
      })

    assert json_response(conn, 401)["error"] == "invalid_credentials"
  end

  test "GET /api/v1/me without a token is 401" do
    conn = get(build_conn(), ~p"/api/v1/me")
    assert json_response(conn, 401)["error"] == "missing_bearer_token"
  end

  test "GET /api/v1/me returns the token's user and tenant", %{token: token, scope: scope} do
    conn = build_conn() |> auth(token) |> get(~p"/api/v1/me")
    data = json_response(conn, 200)["data"]

    assert data["user"]["email"] == scope.user.email
    assert data["tenant"]["id"] == scope.tenant.id
  end

  test "GET /api/v1/servers lists the tenant's servers", %{token: token, server: server} do
    conn = build_conn() |> auth(token) |> get(~p"/api/v1/servers")
    data = json_response(conn, 200)["data"]

    assert Enum.any?(data, &(&1["id"] == server.id))
  end

  test "GET /api/v1/apps/:slug resolves by slug", %{token: token, app: app} do
    conn = build_conn() |> auth(token) |> get(~p"/api/v1/apps/#{app.slug}")
    assert json_response(conn, 200)["data"]["id"] == app.id
  end

  test "POST /api/v1/apps/:id/deployments enqueues a deploy", %{token: token, app: app} do
    conn = build_conn() |> auth(token) |> json_post(~p"/api/v1/apps/#{app.id}/deployments", %{})
    data = json_response(conn, 201)["data"]

    assert data["status"] == "queued"
    assert data["triggered_by"] == "api"
    assert data["wait_reason"] == nil
    assert_enqueued(worker: CleatDeploy.Workers.DeployWorker)
  end

  test "GET /api/v1/apps/:id/deployments includes wait_reason for FIFO", %{
    token: token,
    app: app
  } do
    {:ok, first} = Deployments.create_deployment(app, %{git_sha: "ahead"})
    {:ok, _} = Deployments.mark_running(first)
    {:ok, second} = Deployments.create_deployment(app, %{git_sha: "behind"})

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/apps/#{app.id}/deployments")
    data = json_response(conn, 200)["data"]
    behind = Enum.find(data, &(&1["id"] == second.id))

    assert behind["wait_reason"] == "app_fifo"
  end

  test "GET /api/v1/deployments/:id returns the deployment with its log", %{
    token: token,
    app: app
  } do
    {:ok, deployment, _job} = Deployments.enqueue_deployment(app, %{git_sha: "manual"})

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/deployments/#{deployment.id}")
    data = json_response(conn, 200)["data"]

    assert data["id"] == deployment.id
    assert Map.has_key?(data, "log")
  end

  test "cannot read another tenant's app", %{token: token} do
    other = TenancyFixtures.scope_fixture()
    other_server = TenancyFixtures.server_fixture(other)
    other_app = TenancyFixtures.app_fixture(other, other_server)

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/apps/#{other_app.slug}")
    assert json_response(conn, 404)["error"] == "not_found"
  end

  test "a revoked token is rejected", %{scope: scope} do
    {:ok, raw, api_token} = Accounts.create_api_token(scope.user, scope.tenant, %{name: "temp"})
    assert :ok = Accounts.revoke_api_token(scope.user, api_token.id)

    conn = build_conn() |> auth(raw) |> get(~p"/api/v1/me")
    assert json_response(conn, 401)["error"] == "invalid_or_revoked_token"
  end

  test "DELETE /api/v1/auth/tokens revokes the current token", %{token: token} do
    assert response(build_conn() |> auth(token) |> delete(~p"/api/v1/auth/tokens"), 204) == ""

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/me")
    assert json_response(conn, 401)["error"] == "invalid_or_revoked_token"
  end

  test "PATCH /api/v1/apps/:id updates runtime_apt_packages", %{token: token, app: app} do
    conn =
      build_conn()
      |> auth(token)
      |> json_patch(~p"/api/v1/apps/#{app.id}", %{runtime_apt_packages: ["ffmpeg", "webp"]})

    data = json_response(conn, 200)["data"]
    assert data["runtime_apt_packages"] == ["ffmpeg", "webp"]
  end

  test "PATCH /api/v1/apps/:id updates branch and auto-deploy", %{token: token, app: app} do
    conn =
      build_conn()
      |> auth(token)
      |> json_patch(~p"/api/v1/apps/#{app.id}", %{branch: "develop", auto_deploy: false})

    data = json_response(conn, 200)["data"]
    assert data["branch"] == "develop"
    assert data["auto_deploy"] == false
  end

  test "PATCH /api/v1/apps/:id turns indexing on", %{token: token, scope: scope, server: server} do
    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "landing-drop",
        host: "landing-drop.example.com",
        runtime: "static"
      })

    conn =
      build_conn()
      |> auth(token)
      |> json_patch(~p"/api/v1/apps/#{app.id}", %{indexable: true})

    data = json_response(conn, 200)["data"]
    assert data["indexable"] == true
  end

  test "POST /api/v1/apps/:app/cancel cancels the active deploy", %{token: token, app: app} do
    {:ok, deployment, _job} = Deployments.enqueue_deployment(app, %{git_sha: "manual"})

    conn = build_conn() |> auth(token) |> json_post(~p"/api/v1/apps/#{app.id}/cancel", %{})
    data = json_response(conn, 200)["data"]

    assert data["id"] == deployment.id
    assert data["status"] == "failed"
  end

  test "POST /api/v1/apps/:app/cancel is 409 when nothing is active", %{token: token, app: app} do
    conn = build_conn() |> auth(token) |> json_post(~p"/api/v1/apps/#{app.id}/cancel", %{})
    assert json_response(conn, 409)["error"] == "no_active_deployment"
  end

  test "PATCH /api/v1/apps/:id updates the host (normalized)", %{token: token, app: app} do
    conn =
      build_conn()
      |> auth(token)
      |> json_patch(~p"/api/v1/apps/#{app.id}", %{host: "New.Host.Example.com"})

    assert json_response(conn, 200)["data"]["host"] == "new.host.example.com"
  end

  test "PATCH rejects a host already used on the same server", %{
    token: token,
    scope: scope,
    server: server,
    app: app
  } do
    other = TenancyFixtures.app_fixture(scope, server)

    conn =
      build_conn()
      |> auth(token)
      |> json_patch(~p"/api/v1/apps/#{app.id}", %{host: other.host})

    assert json_response(conn, 422)["details"]["host"] == ["has already been taken"]
  end

  test "DELETE /api/v1/apps/:id deletes the app", %{token: token, app: app} do
    conn = build_conn() |> auth(token) |> delete(~p"/api/v1/apps/#{app.id}")
    assert response(conn, 204) == ""

    assert build_conn()
           |> auth(token)
           |> get(~p"/api/v1/apps/#{app.id}")
           |> json_response(404)
  end

  test "GET /api/v1/apps/:app/logs returns recent journal lines", %{token: token, app: app} do
    conn = build_conn() |> auth(token) |> get(~p"/api/v1/apps/#{app.id}/logs")
    data = json_response(conn, 200)["data"]

    assert data["unit"] == app.systemd_unit
    assert Enum.any?(data["lines"], &String.contains?(&1, "started"))
  end

  test "GET /api/v1/apps/:app/logs rejects static apps", %{
    token: token,
    scope: scope,
    server: server
  } do
    static = TenancyFixtures.app_fixture(scope, server, %{runtime: "static", github_repo: nil})

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/apps/#{static.id}/logs")
    assert json_response(conn, 422)["error"] == "runtime_logs_unavailable"
  end

  test "GET /api/v1/apps/:app/logs accepts since and tail", %{token: token, app: app} do
    conn =
      build_conn()
      |> auth(token)
      |> get(~p"/api/v1/apps/#{app.id}/logs?since=1h&tail=50")

    data = json_response(conn, 200)["data"]
    assert is_list(data["lines"])
  end

  test "GET /api/v1/apps/:app/logs rejects an invalid since", %{token: token, app: app} do
    conn = build_conn() |> auth(token) |> get(~p"/api/v1/apps/#{app.id}/logs?since=nope")
    assert json_response(conn, 422)["error"] == "invalid_request"
  end

  test "GET /api/v1/apps/:app/logs rejects an invalid tail and grep", %{token: token, app: app} do
    tail = build_conn() |> auth(token) |> get(~p"/api/v1/apps/#{app.id}/logs?tail=0")
    assert json_response(tail, 422)["error"] == "invalid_request"

    grep =
      build_conn()
      |> auth(token)
      |> get(~p"/api/v1/apps/#{app.id}/logs?grep=#{String.duplicate("a", 201)}")

    assert json_response(grep, 422)["error"] == "invalid_request"
  end

  test "GET /api/v1/apps/:app/logs ignores a unit override", %{token: token, app: app} do
    conn = build_conn() |> auth(token) |> get(~p"/api/v1/apps/#{app.id}/logs?unit=other")
    data = json_response(conn, 200)["data"]

    assert data["unit"] == app.systemd_unit
  end

  test "GET /api/v1/apps/:app/logs is 502 when the journal runner fails", %{
    token: token,
    app: app
  } do
    expect(RuntimeLogsMock, :run, fn _subject, _argv -> {:error, "boom"} end)

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/apps/#{app.id}/logs")
    body = json_response(conn, 502)

    assert body["error"] == "runtime_logs_failed"
    assert body["message"] == "boom"
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp json_post(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp json_patch(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> patch(path, Jason.encode!(body))
  end
end
