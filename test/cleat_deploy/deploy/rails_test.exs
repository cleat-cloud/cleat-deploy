defmodule CleatDeploy.Deploy.RailsTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.{AppManifest, Rails, ServerProvision}
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    {:ok, app, _webhook_status} =
      Apps.create_app(scope, %{
        name: "Loja",
        slug: "loja",
        github_repo: "puppe1990/loja",
        host: "loja.example.com",
        runtime: "rails",
        port: 4030,
        server_id: server.id
      })

    app = Apps.get_app!(scope, app.id)

    %{app: app, config: App.deploy_config(app)}
  end

  test "rails apps default to /opt and a rails-<slug> systemd unit", %{app: app} do
    assert app.release_path == "/opt/loja"
    assert app.systemd_unit == "rails-loja"
    assert App.main_language(app) == "Ruby"
  end

  test "provision script writes a systemd unit and a Caddy reverse proxy", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "Provisioning Rails host loja.example.com on port 4030"
    assert script =~ "/etc/systemd/system/rails-loja.service"
    assert script =~ "ExecStart=/bin/bash /opt/loja/current/start.sh"
    assert script =~ "Environment=RAILS_ENV=production"
    assert script =~ "Environment=PORT=4030"
    assert script =~ "reverse_proxy 127.0.0.1:4030"
  end

  test "build script installs Ruby, bundles, precompiles, migrates, and restarts", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = Rails.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    assert script =~ "mise install \"ruby@${RUBY_VERSION}\""
    assert script =~ "bundle install"
    assert script =~ "bundle exec rails assets:precompile"
    assert script =~ "bundle exec rails db:prepare"
    assert script =~ "bundle exec puma -C config/puma.rb"
    assert script =~ "/opt/loja/releases/build"
    assert script =~ "sudo systemctl restart rails-loja"
  end

  test "manifest ruby_version and start_command win over detection" do
    app = %App{
      name: "Loja",
      slug: "loja",
      host: "loja.example.com",
      runtime: "rails",
      port: 3000,
      release_path: "/opt/loja",
      systemd_unit: "rails-loja"
    }

    config = App.deploy_config(app)

    manifest = %AppManifest{
      runtime: "rails",
      ruby_version: "3.2.2",
      start_command: "bin/rails server -b 0.0.0.0"
    }

    script = Rails.remote_build_script(nil, app, config, "abc", "/tmp/src.tar.gz", manifest)

    assert script =~ ~s|RUBY_VERSION="3.2.2"|
    assert script =~ "START_CMD='bin/rails server -b 0.0.0.0'"
  end
end
