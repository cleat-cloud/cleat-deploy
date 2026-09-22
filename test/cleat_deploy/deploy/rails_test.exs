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

  test "release_command replaces db:prepare and runs before the restart", %{
    app: app,
    config: config
  } do
    manifest = %AppManifest{
      runtime: "rails",
      release_command: ["bundle exec rails db:chatwoot_prepare"],
      release_timeout_s: 600
    }

    script = Rails.remote_build_script(nil, app, config, "abc", "/tmp/src.tar.gz", manifest)

    refute script =~ "bundle exec rails db:prepare"
    assert script =~ "Skipping db:prepare (release_command is set"
    assert script =~ "Running release command (1/1)"
    assert script =~ "timeout 600 bash /tmp/cleat_release_cmd.sh"
    assert script =~ "export RAILS_ENV=production"
    assert script =~ "source /etc/loja/env"

    assert occurrence(script, "Running release command") <
             occurrence(script, "Restarting rails-loja")
  end

  test "keeps db:prepare when there is no release command", %{app: app, config: config} do
    script =
      Rails.remote_build_script(nil, app, config, "abc", "/tmp/src.tar.gz", %AppManifest{
        runtime: "rails"
      })

    assert script =~ "bundle exec rails db:prepare"
    refute script =~ "Running release command"
  end

  test "asset pipeline honours the node version, the lockfiles and a persistent cache", %{
    app: app,
    config: config
  } do
    script =
      Rails.remote_build_script(nil, app, config, "abc", "/tmp/src.tar.gz", %AppManifest{
        runtime: "rails",
        node_version: "20"
      })

    assert script =~ ~s|NODE_MAJOR='20'|
    assert script =~ "setup_${NODE_MAJOR}.x"
    assert script =~ "engines"
    assert script =~ "yarn install --frozen-lockfile"
    assert script =~ "pnpm install --frozen-lockfile"
    assert script =~ "npm ci --no-audit --no-fund"
    assert script =~ "export NODE_ENV=production"
    assert script =~ ~s|BUILD_CACHE='/opt/loja/data/build-cache'|
    assert script =~ ~s|ln -sfn "$BUILD_CACHE/vite" tmp/cache/vite|
    # The cache inside the build tree belongs to the build user: creating it
    # with sudo left it owned by root and the symlink failed ("Permission
    # denied"), aborting the build before assets:precompile.
    assert script =~ ~s|sudo mkdir -p "$BUILD_CACHE/vite"|
    assert script =~ "mkdir -p tmp/cache"
    refute script =~ ~s|sudo mkdir -p "$BUILD_CACHE/vite" tmp/cache|
    # The clone has no .git, so husky in a prepare script can only fail.
    assert script =~ "export HUSKY=0"
  end

  test "the node major and the package manager work on a VM that has neither", %{
    app: app,
    config: config
  } do
    script =
      Rails.remote_build_script(nil, app, config, "abc", "/tmp/src.tar.gz", %AppManifest{
        runtime: "rails"
      })

    # `engines.node` read with node itself never works on a fresh VM (node is the
    # thing being installed), so it is parsed from the JSON instead.
    assert script =~ "package_json_node_major()"
    assert script =~ "python3 -c"
    refute script =~ "node -e"

    # corepack writes its shims into the Node install dir (root) and is not
    # always present; a silent failure here is what left `pnpm: command not
    # found` in the middle of a build.
    assert script =~ "enable_package_manager pnpm"
    assert script =~ "enable_package_manager yarn"
    assert script =~ "sudo corepack enable"
    assert script =~ ~s|sudo npm install -g "$1"|
  end

  defp occurrence(script, snippet) do
    {position, _length} = :binary.match(script, snippet)
    position
  end
end
