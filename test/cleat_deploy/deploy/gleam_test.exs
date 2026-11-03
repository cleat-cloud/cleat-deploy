defmodule CleatDeploy.Deploy.GleamTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.{AppManifest, Gleam, ServerProvision}
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    {:ok, app, _webhook_status} =
      Apps.create_app(scope, %{
        name: "Minha App",
        slug: "minha-app",
        github_repo: "puppe1990/minha-app",
        host: "minha-app.example.com",
        runtime: "gleam",
        port: 4040,
        server_id: server.id
      })

    app = Apps.get_app!(scope, app.id)

    %{app: app, config: App.deploy_config(app)}
  end

  test "gleam apps default to /opt and a gleam-<slug> systemd unit", %{app: app} do
    assert app.release_path == "/opt/minha-app"
    assert app.systemd_unit == "gleam-minha-app"
    assert App.main_language(app) == "Gleam"
  end

  test "provision script writes a systemd unit and a Caddy reverse proxy", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "Provisioning Gleam host minha-app.example.com on port 4040"
    assert script =~ "/etc/systemd/system/gleam-minha-app.service"
    assert script =~ "ExecStart=/bin/bash /opt/minha-app/current/start.sh"
    assert script =~ "Environment=PORT=4040"
    assert script =~ "Environment=CLEAT_DATA_DIR=/opt/minha-app/data"
    assert script =~ "reverse_proxy 127.0.0.1:4040"
  end

  test "build script installs Erlang and Gleam and publishes the shipment", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = Gleam.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    assert script =~ "mise install erlang@28.4.1 gleam@1.18.1 rebar@3.27.0"
    assert script =~ "gleam deps download"
    assert script =~ "gleam export erlang-shipment"
    assert script =~ "build/erlang-shipment"
    assert script =~ "/opt/minha-app/releases/build"
    assert script =~ "./entrypoint.sh run"
    assert script =~ "export CLEAT_DATA_DIR=\"$DATA_DIR\""
    assert script =~ "/opt/minha-app/data"
    assert script =~ "sudo systemctl restart gleam-minha-app"
    refute script =~ "mix release"

    assert occurrence(script, "Fixing data ownership for cleat-minha-app") <
             occurrence(script, "Restarting gleam-minha-app")

    refute script =~ "chmod -R a+rX"
  end

  test "publish empties the reused release dir with find, dotfiles included (#246)" do
    slug = "#{Faker.Lorem.word()}-#{Faker.Lorem.word()}"

    app = %App{
      name: Faker.Company.name(),
      slug: slug,
      host: "#{slug}.example.com",
      runtime: "gleam",
      port: 4040,
      release_path: "/opt/#{slug}",
      systemd_unit: "gleam-#{slug}"
    }

    config = App.deploy_config(app)

    script =
      Gleam.remote_build_script(
        nil,
        app,
        config,
        Faker.Internet.user_name(),
        "/tmp/src.tar.gz",
        %AppManifest{runtime: "gleam"}
      )

    # `rm -rf "$DIR"/*` does not match dotfiles: leftovers from the previous
    # release survived the copy.
    refute script =~ ~S|rm -rf "${RELEASE_DIR:?}"/*|
    # Only the release dir is emptied — never the app root that holds data/.
    refute script =~ "find '/opt/#{slug}' -mindepth 1 -delete"
    assert script =~ "sudo find '/opt/#{slug}/releases/build' -mindepth 1 -delete"

    assert occurrence(script, "-mindepth 1 -delete") <
             occurrence(script, ~s|sudo cp -a "$SHIP_DIR/."|)
  end

  # A shipment carries no ERTS, so erl has to leave the build user's mise
  # install and live on PATH for the unprivileged unit.
  test "build script links the Erlang binaries onto PATH for the app unit", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = Gleam.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    assert script =~ "for bin in erl erlc escript epmd"
    assert script =~ ~s(sudo ln -sfn "$ERL_BIN_DIR/$bin" "/usr/local/bin/$bin")
  end

  test "build script refuses a project targeting JavaScript", %{app: app, config: config} do
    manifest = AppManifest.resolve(nil, app)
    script = Gleam.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    assert script =~ "target[[:space:]]*=[[:space:]]*\"javascript\""
    assert script =~ "the gleam runtime builds the Erlang target only"
  end

  test "manifest gleam_version and build_command win over the defaults" do
    app = %App{
      name: "Minha App",
      slug: "minha-app",
      host: "minha-app.example.com",
      runtime: "gleam",
      port: 4040,
      release_path: "/opt/minha-app",
      systemd_unit: "gleam-minha-app"
    }

    config = App.deploy_config(app)

    manifest = %AppManifest{
      runtime: "gleam",
      gleam_version: "1.17.0",
      build_command:
        "gleam deps download && APP_ENV=prod gleam run -m minha_app/migrate && gleam export erlang-shipment"
    }

    script = Gleam.remote_build_script(nil, app, config, "abc", "/tmp/src.tar.gz", manifest)

    assert script =~ "gleam@1.17.0"
    assert script =~ "APP_ENV=prod gleam run -m minha_app/migrate"
    refute script =~ "log \"Exporting Erlang shipment\""
  end

  test "release_command runs after the publish and before the restart", %{
    app: app,
    config: config
  } do
    manifest = %AppManifest{
      runtime: "gleam",
      release_command: ["./entrypoint.sh eval 'minha_app_migrate:main()'"],
      release_timeout_s: 600
    }

    script = Gleam.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    assert script =~ "Running release command (1/1)"

    assert occurrence(script, "Running release command") <
             occurrence(script, "Restarting gleam-minha-app")
  end

  defp occurrence(script, snippet) do
    {position, _length} = :binary.match(script, snippet)
    position
  end
end
