defmodule CleatDeploy.Deploy.StaticTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.{AppManifest, ServerProvision, Static}
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    {:ok, app, _webhook_status} =
      Apps.create_app(scope, %{
        name: "Landing",
        slug: "landing",
        github_repo: "owner/landing",
        host: "landing.example.com",
        runtime: "static",
        server_id: server.id
      })

    app = Apps.get_app!(scope, app.id)

    %{app: app, config: App.deploy_config(app)}
  end

  test "static apps default to /var/www and have no systemd unit", %{app: app} do
    assert app.release_path == "/var/www/landing"
    assert app.systemd_unit in [nil, ""]
  end

  test "caddy serves files with SPA fallback instead of reverse_proxy", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "Provisioning static site landing.example.com"
    assert script =~ "root * /var/www/landing/current"
    assert script =~ "try_files {path} /index.html"
    assert script =~ "file_server"
    refute script =~ "reverse_proxy"
    refute script =~ "systemd"
  end

  test "build script installs node, builds, and publishes the output", %{app: app, config: config} do
    manifest = AppManifest.resolve(nil, app)
    script = Static.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    assert script =~ "npm ci || npm install"
    assert script =~ "npm run build"
    assert script =~ "/var/www/landing/releases/build"
    assert script =~ ~s|PUBLISH_DIR="$candidate"|
    assert script =~ "file_server"
  end

  test "build script honours an explicit build_dir" do
    app = %App{
      name: "X",
      slug: "x",
      host: "x.example.com",
      runtime: "static",
      release_path: "/var/www/x"
    }

    config = App.deploy_config(app)
    manifest = %AppManifest{runtime: "static", build_dir: "dist"}
    script = Static.remote_build_script(nil, app, config, "sha", "/tmp/s.tar.gz", manifest)

    assert script =~ ~s|PUBLISH_DIR="dist"|
    refute script =~ "for candidate in"
  end
end
