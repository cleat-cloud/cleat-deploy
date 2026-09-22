defmodule CleatDeployWeb.GithubWebhookControllerTest do
  use CleatDeployWeb.ConnCase, async: false

  alias CleatDeploy.{Deployments, TenancyFixtures}

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "Trip Planner",
        slug: "trip-planner",
        github_repo: "puppe1990/trip-planner-ia-phx",
        host: "trip.gestaobem.com"
      })

    payload = File.read!("test/support/fixtures/github_push.json")
    signature = sign(payload, app.webhook_secret)

    %{app: app, payload: payload, signature: signature}
  end

  test "returns 401 without signature", %{payload: payload} do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/github", payload)

    assert response(conn, 401) == "invalid signature"
  end

  test "queues deploy on valid push to main", %{payload: payload, signature: signature} do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature)
      |> post(~p"/webhooks/github", payload)

    assert response(conn, 202) == "queued"
    assert_enqueued(worker: CleatDeploy.Workers.DeployWorker)
  end

  test "returns 404 for unknown repo", %{} do
    payload =
      ~s({"ref":"refs/heads/main","after":"abc123","repository":{"full_name":"unknown/repo"}})

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", sign(payload, "secret"))
      |> post(~p"/webhooks/github", payload)

    assert response(conn, 404) == "unknown repo"
  end

  test "returns 400 when repository is missing (no 500)" do
    payload = ~s({"ref":"refs/heads/main","after":"abc123"})

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", sign(payload, "secret"))
      |> post(~p"/webhooks/github", payload)

    assert response(conn, 400) == "missing repository"
  end

  test "ignores push to a different branch with the expected deploy branch" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "PratoAI",
        slug: "prato-ai-#{System.unique_integer()}",
        github_repo: "gestao-bem/prato-ai-#{System.unique_integer()}",
        branch: "deploy-cleat",
        host: "pratoai.gestaobem.com"
      })

    payload =
      Jason.encode!(%{
        "ref" => "refs/heads/main",
        "after" => "abc123def456",
        "repository" => %{"full_name" => app.github_repo}
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", sign(payload, app.webhook_secret))
      |> post(~p"/webhooks/github", payload)

    body = response(conn, 200)
    assert body =~ "ignored"
    assert body =~ "main"
    assert body =~ "deploy-cleat"
    refute_enqueued(worker: CleatDeploy.Workers.DeployWorker)
  end

  test "queues deploy when the push matches a non-main deploy branch" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "PratoAI",
        slug: "prato-ai-#{System.unique_integer()}",
        github_repo: "gestao-bem/prato-ai-#{System.unique_integer()}",
        branch: "deploy-cleat",
        host: "pratoai.gestaobem.com"
      })

    payload =
      Jason.encode!(%{
        "ref" => "refs/heads/deploy-cleat",
        "after" => "abc123def456",
        "repository" => %{"full_name" => app.github_repo}
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", sign(payload, app.webhook_secret))
      |> post(~p"/webhooks/github", payload)

    assert response(conn, 202) == "queued"
    assert_enqueued(worker: CleatDeploy.Workers.DeployWorker)
  end

  test "deploys only the instance that owns the pushed branch" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    repo = "puppe1990/purplestock-#{System.unique_integer()}"

    production =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "Purple Stock",
        slug: "purplestock-#{System.unique_integer()}",
        github_repo: repo,
        branch: "main",
        host: "purplestock.gestaobem.com"
      })

    staging =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "Purple Stock Staging",
        slug: "purplestock-staging-#{System.unique_integer()}",
        github_repo: repo,
        branch: "staging",
        host: "purplestock-staging.gestaobem.com"
      })

    assert staging.webhook_secret == production.webhook_secret

    payload =
      Jason.encode!(%{
        "ref" => "refs/heads/staging",
        "after" => "abc123def456",
        "repository" => %{"full_name" => repo}
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", sign(payload, production.webhook_secret))
      |> post(~p"/webhooks/github", payload)

    assert response(conn, 202) == "queued"

    assert [job] = all_enqueued(worker: CleatDeploy.Workers.DeployWorker)
    deployment = Deployments.get_deployment!(job.args["deployment_id"])

    assert deployment.app_id == staging.id
    assert deployment.git_ref == "staging"
    assert deployment.git_sha == "abc123def456"
  end

  defp sign(body, secret) do
    "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
  end
end
