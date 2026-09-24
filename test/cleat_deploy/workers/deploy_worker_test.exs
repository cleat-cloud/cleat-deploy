defmodule CleatDeploy.Workers.DeployWorkerTest do
  use CleatDeploy.DataCase, async: false

  import Mox

  use Oban.Testing,
    repo: CleatDeploy.Repo,
    notifier: Oban.Notifiers.Isolated,
    testing: :manual

  alias CleatDeploy.{Deployments, Workers.DeployWorker}
  alias CleatDeploy.Deploy.RunnerMock
  alias CleatDeploy.TenancyFixtures

  setup :verify_on_exit!

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    %{scope: scope, server: server, app: app}
  end

  test "marks deployment successful when runner succeeds", %{app: app} do
    expect(RunnerMock, :deploy, fn deployment ->
      assert deployment.status == :running
      {:ok, "deploy ok"}
    end)

    {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "abc123"})
    assert :ok = perform_job(DeployWorker, %{"deployment_id" => deployment.id})

    deployment = Deployments.for_app(app) |> List.first()
    assert deployment.status == :success
  end

  test "marks deployment failed when runner errors", %{app: app} do
    expect(RunnerMock, :deploy, fn _deployment -> {:error, "ssh failed"} end)

    {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "abc123"})
    assert {:error, "ssh failed"} = perform_job(DeployWorker, %{"deployment_id" => deployment.id})

    deployment = Deployments.for_app(app) |> List.first()
    assert deployment.status == :failed
  end

  test "marks deployment failed when the runner raises", %{app: app} do
    expect(RunnerMock, :deploy, fn _deployment -> raise "cloak blew up" end)

    {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "abc123"})

    assert {:error, "cloak blew up"} =
             perform_job(DeployWorker, %{"deployment_id" => deployment.id})

    deployment = Deployments.get_deployment!(deployment.id)
    assert deployment.status == :failed
    assert deployment.log =~ "cloak blew up"
  end

  test "marks deployment failed when the runner exits", %{app: app} do
    expect(RunnerMock, :deploy, fn _deployment -> exit(:timeout) end)

    {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "abc123"})

    assert {:error, "exit: :timeout"} =
             perform_job(DeployWorker, %{"deployment_id" => deployment.id})

    deployment = Deployments.get_deployment!(deployment.id)
    assert deployment.status == :failed
    assert deployment.log =~ "exit: :timeout"
  end

  test "snoozes when another deploy is already running on the same server", %{app: app} do
    {:ok, first} = Deployments.create_deployment(app, %{git_sha: "first"})
    {:ok, _} = Deployments.mark_running(first)

    {:ok, second} = Deployments.create_deployment(app, %{git_sha: "second"})

    assert {:snooze, 20} = perform_job(DeployWorker, %{"deployment_id" => second.id})

    second = Deployments.get_deployment!(second.id)
    assert second.status == :queued
  end

  test "deploys a second app while another is running on the same server", %{
    scope: scope,
    server: server,
    app: app
  } do
    other =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "other-parallel",
        name: "Other Parallel",
        github_repo: "owner/other-parallel",
        host: "other-parallel.example.com"
      })

    expect(RunnerMock, :deploy, fn deployment ->
      assert deployment.status == :running
      {:ok, "deploy ok"}
    end)

    {:ok, first} = Deployments.create_deployment(app, %{git_sha: "first"})
    {:ok, _} = Deployments.mark_running(first)

    {:ok, second} = Deployments.create_deployment(other, %{git_sha: "second"})
    assert :ok = perform_job(DeployWorker, %{"deployment_id" => second.id})

    second = Deployments.get_deployment!(second.id)
    assert second.status == :success
  end
end
