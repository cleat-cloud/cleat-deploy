defmodule CleatDeploy.Deploy.DropTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.{AppManifest, Ssh, Static}
  alias CleatDeploy.Deployments
  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    static =
      TenancyFixtures.app_fixture(scope, server, %{runtime: "static", github_repo: nil})

    %{scope: scope, server: server, static: static}
  end

  test "a static app can be created without a github repo" do
    attrs = %{
      name: "Drop",
      slug: "drop-#{System.unique_integer([:positive])}",
      host: "drop.example.com",
      runtime: "static"
    }

    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    assert {:ok, app, _} = Apps.create_app(scope, Map.put(attrs, :server_id, server.id))
    assert app.github_repo in [nil, ""]
  end

  test "a phoenix app still requires a github repo" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    attrs = %{
      name: "NoRepo",
      slug: "no-repo-#{System.unique_integer([:positive])}",
      host: "x.com"
    }

    assert {:error, changeset} = Apps.create_app(scope, Map.put(attrs, :server_id, server.id))
    assert %{github_repo: ["can't be blank"]} = errors_on(changeset)
  end

  test "enqueue_drop records the source and artifact path", %{scope: scope, static: app} do
    path = Path.join(System.tmp_dir!(), "drop_#{System.unique_integer([:positive])}.tar.gz")
    File.write!(path, "x")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %Deployment{} = deployment, _job} =
             Deployments.enqueue_drop(scope, app, %{artifact_path: path})

    assert deployment.source == "drop"
    assert deployment.artifact_path == path
    assert deployment.triggered_by == "drop"
  end

  test "remote_drop_script publishes the archive root without building", %{static: app} do
    manifest = AppManifest.resolve(nil, app)
    config = App.deploy_config(app)
    script = Static.remote_drop_script(app, config, "abc", "/tmp/drop.tar.gz", manifest)

    assert script =~ "tar -xzf /tmp/drop.tar.gz"
    assert script =~ "/var/www/#{app.slug}/releases/build"
    assert script =~ "file_server"
    refute script =~ "npm run build"
    refute script =~ "git clone"
  end

  test "run_drop fails cleanly when the artifact is gone", %{server: server, static: app} do
    deployment = %Deployment{
      artifact_path: "/tmp/cleat-missing-#{System.unique_integer()}.tar.gz"
    }

    assert {:error, message} = Ssh.run_drop(deployment, app, server)
    assert message =~ "not found"
  end

  test "static apps default without a systemd unit", %{static: app} do
    assert %App{} = app
    assert app.runtime == "static"
  end
end
