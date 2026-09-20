defmodule CleatDeploy.Deploy.ServerProvisionTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.Deploy.ServerProvision
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    {:ok, app, _webhook_status} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Phoenix TTS",
        slug: "phoenix-tts",
        github_repo: "puppe1990/phoenix_tts",
        host: "tts.gestaobem.com",
        port: 4004,
        systemd_unit: "phoenix_tts",
        release_path: "/opt/phoenix_tts",
        server_id: server.id
      })

    config = App.deploy_config(app)
    %{app: app, config: config, scope: scope, server: server}
  end

  test "provision_script creates systemd unit, data dir, and caddy site", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "Provisioning host tts.gestaobem.com on port 4004"
    assert script =~ "/etc/systemd/system/phoenix_tts.service"
    assert script =~ "ExecStart=/opt/phoenix_tts/current/bin/phoenix_tts start"
    assert script =~ "sudo mkdir -p '/etc/phoenix_tts' '/var/lib/phoenix_tts'"
    assert script =~ "Environment=CLEAT_DATA_DIR=/var/lib/phoenix_tts"
    assert script =~ "tts.gestaobem.com {"
    assert script =~ "reverse_proxy 127.0.0.1:4004"
    assert script =~ "Writing Caddy site tts.gestaobem.com"
    assert script =~ "sudo awk -v site='tts.gestaobem.com'"
    assert script =~ ~s|sudo install -m 0644 -o root -g root "$TMPFILE" "$CADDYFILE"|
  end

  test "node apps get a persistent data dir outside the release", %{
    scope: scope,
    server: server
  } do
    {:ok, app, _webhook_status} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Leitor",
        slug: "leitor",
        github_repo: "owner/leitor",
        host: "leitor.example.com",
        runtime: "node",
        server_id: server.id
      })

    config = App.deploy_config(app)
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "Environment=CLEAT_DATA_DIR=/opt/leitor/data"
    assert script =~ "sudo mkdir -p '/etc/leitor' '/opt/leitor/data'"
  end

  test "provision_script rewrites an existing caddy site when the port changes", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(%{app | port: 4088}, config, manifest)

    assert script =~ "reverse_proxy 127.0.0.1:4088"
    assert script =~ "Writing Caddy site tts.gestaobem.com"
    refute script =~ "reverse_proxy 127.0.0.1:4004"
  end

  test "migrate_script falls back to release eval when bin/migrate is absent", %{config: config} do
    script = ServerProvision.migrate_script(config)

    assert script =~ "bin/migrate"
    assert script =~ "release eval"
    assert script =~ "Ecto.Migrator.with_repo"
  end

  test "migrate_script skips release eval migrations when app has no ecto_repos" do
    config = %{
      release_path: "/opt/rapid_tools",
      release_name: "rapid_tools",
      env_file: "/etc/rapid_tools/env"
    }

    script = ServerProvision.migrate_script(config)

    assert script =~ "Application.get_env(:rapid_tools, :ecto_repos, [])"
    assert script =~ "[] -> :ok"
    refute script =~ "fetch_env!"
  end

  test "migrate_script still runs ecto migrations when ecto_repos is configured", %{
    config: config
  } do
    script = ServerProvision.migrate_script(config)

    assert script =~ "Application.get_env(:phoenix_tts, :ecto_repos, [])"
    assert script =~ "Ecto.Migrator.with_repo"
    refute script =~ "fetch_env!"
  end

  test "reload_caddy_script reloads or restarts caddy", %{config: _config} do
    script = ServerProvision.reload_caddy_script()

    assert script =~ "Reloading Caddy"
    assert script =~ "systemctl reload caddy"
  end

  test "IP hosts get an http:// site to avoid a broken HTTPS redirect", %{app: app} do
    app = %{app | host: "203.0.113.10"}
    config = App.deploy_config(app)
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "http://203.0.113.10 {"
    assert script =~ "Writing Caddy site http://203.0.113.10"
    assert script =~ "reverse_proxy 127.0.0.1:4004"
  end

  test "provision_script replaces caddyfile when manifest requests replace", %{
    app: app,
    config: config
  } do
    manifest = %AppManifest{
      caddy_mode: "replace",
      caddyfile: "deploy/Caddyfile",
      memory_max_mb: 1024
    }

    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "Installing custom Caddyfile (deploy/Caddyfile)"
    assert script =~ ~s|sudo cp "$BUILD_DIR/deploy/Caddyfile" /etc/caddy/Caddyfile|
    assert script =~ "MemoryMax=1024M"
    refute script =~ "Writing Caddy site"
  end
end
