defmodule CleatDeploy.Deploy.NodeTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.{AppManifest, Node, ServerProvision}
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    {:ok, app, _webhook_status} =
      Apps.create_app(scope, %{
        name: "Cleat Web",
        slug: "cleat-web",
        github_repo: "puppe1990/cleat-web",
        host: "web.example.com",
        runtime: "node",
        port: 4020,
        server_id: server.id
      })

    app = Apps.get_app!(scope, app.id)

    %{app: app, config: App.deploy_config(app)}
  end

  test "node apps default to /opt and a node-<slug> systemd unit", %{app: app} do
    assert app.release_path == "/opt/cleat-web"
    assert app.systemd_unit == "node-cleat-web"
    assert App.main_language(app) == "JavaScript"
  end

  test "provision script writes a systemd unit and a Caddy reverse proxy", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "Provisioning Node host web.example.com on port 4020"
    assert script =~ "/etc/systemd/system/node-cleat-web.service"
    assert script =~ "ExecStart=/bin/bash /opt/cleat-web/current/start.sh"
    assert script =~ "Environment=PORT=4020"
    assert script =~ "reverse_proxy 127.0.0.1:4020"
  end

  test "build script installs node, builds, resolves a start command, and restarts", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = Node.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    assert script =~ "Installing Node.js"
    assert script =~ "npm ci || npm install"
    assert script =~ "npm run build"
    assert script =~ ".output/server/index.mjs"
    assert script =~ "next start"
    assert script =~ "/opt/cleat-web/releases/build"
    assert script =~ "start.sh"
    assert script =~ "sudo systemctl restart node-cleat-web"
    # build dir must not leak (it accumulated ~50 GB in production)
    assert script =~ ~s|trap 'rm -rf "$BUILD_DIR"' EXIT|
  end

  test "manifest custom build/start commands and node version win over detection" do
    app = %App{
      name: "Web",
      slug: "web",
      host: "web.example.com",
      runtime: "node",
      port: 3000,
      release_path: "/opt/web",
      systemd_unit: "node-web"
    }

    config = App.deploy_config(app)

    manifest = %AppManifest{
      runtime: "node",
      build_command: "pnpm build",
      start_command: "pnpm start",
      node_version: "20"
    }

    script = Node.remote_build_script(nil, app, config, "abc", "/tmp/src.tar.gz", manifest)

    assert script =~ "pnpm build"
    assert script =~ "START_CMD='pnpm start'"
    assert script =~ ~s|NODE_MAJOR="20"|
  end
end
