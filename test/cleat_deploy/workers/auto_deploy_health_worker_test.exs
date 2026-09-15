defmodule CleatDeploy.Workers.AutoDeployHealthWorkerTest do
  use CleatDeploy.DataCase, async: false

  import Mox

  use Oban.Testing,
    repo: CleatDeploy.Repo,
    notifier: Oban.Notifiers.Isolated,
    testing: :manual

  alias CleatDeploy.TenancyFixtures
  alias CleatDeploy.Workers.AutoDeployHealthWorker

  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:cleat_deploy, :dns_resolver)
    Application.put_env(:cleat_deploy, :dns_resolver, CleatDeploy.Deploy.DnsMock)

    on_exit(fn ->
      if previous do
        Application.put_env(:cleat_deploy, :dns_resolver, previous)
      else
        Application.delete_env(:cleat_deploy, :dns_resolver)
      end
    end)

    :ok
  end

  test "does not set Oban unique options that Turso cannot parse" do
    opts = AutoDeployHealthWorker.__opts__()
    refute Keyword.get(opts, :unique)
  end

  test "reconciles stale server IPs from app DNS and succeeds without GitHub token" do
    scope = TenancyFixtures.scope_fixture()

    server =
      TenancyFixtures.server_fixture(scope, %{name: "stale-lightsail", host_ip: "52.0.157.89"})

    TenancyFixtures.app_fixture(scope, server, %{
      slug: "ops-app",
      host: "app.gestaobem.com",
      github_repo: "puppe1990/ops-app-#{System.unique_integer()}"
    })

    stub(CleatDeploy.Deploy.DnsMock, :lookup_a, fn "app.gestaobem.com" ->
      {:ok, ["52.73.89.19"]}
    end)

    stub(CleatDeploy.AWS.LightsailMock, :list_instances, fn _region -> {:ok, []} end)
    stub(CleatDeploy.HetznerMock, :list_instances, fn _location -> {:ok, []} end)

    assert :ok = perform_job(AutoDeployHealthWorker, %{})

    reloaded = CleatDeploy.Servers.get_server!(scope, server.id)
    assert reloaded.host_ip == "52.73.89.19"
  end

  test "fails deploys whose worker died with a previous boot" do
    scope = TenancyFixtures.scope_fixture()

    server =
      TenancyFixtures.server_fixture(scope, %{name: "orphan-host", host_ip: "52.0.157.89"})

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "orphan-app",
        host: "orphan.gestaobem.com",
        github_repo: "puppe1990/orphan-app-#{System.unique_integer()}"
      })

    {:ok, deployment} = CleatDeploy.Deployments.create_deployment(app, %{git_sha: "orphan"})
    {:ok, _running} = CleatDeploy.Deployments.mark_running(deployment)

    stub(CleatDeploy.Deploy.DnsMock, :lookup_a, fn "orphan.gestaobem.com" ->
      {:ok, ["52.73.89.19"]}
    end)

    stub(CleatDeploy.AWS.LightsailMock, :list_instances, fn _region -> {:ok, []} end)
    stub(CleatDeploy.HetznerMock, :list_instances, fn _location -> {:ok, []} end)

    assert :ok = perform_job(AutoDeployHealthWorker, %{})

    assert CleatDeploy.Deployments.get_deployment!(deployment.id).status == :failed
    refute CleatDeploy.Deployments.deploying?(app)
  end
end
