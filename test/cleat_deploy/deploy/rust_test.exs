defmodule CleatDeploy.Deploy.RustTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.{AppManifest, Rust, ServerProvision}
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    {:ok, app, _webhook_status} =
      Apps.create_app(scope, %{
        name: "Hello Loco",
        slug: "hello-loco",
        github_repo: "puppe1990/hello-loco",
        host: "hello-loco.example.com",
        runtime: "rust",
        port: 4040,
        server_id: server.id
      })

    app = Apps.get_app!(scope, app.id)

    %{app: app, config: App.deploy_config(app)}
  end

  test "rust apps default to /opt and a rust-<slug> systemd unit", %{app: app} do
    assert app.release_path == "/opt/hello-loco"
    assert app.systemd_unit == "rust-hello-loco"
    assert App.main_language(app) == "Rust"
  end

  test "provision script writes a systemd unit and a Caddy reverse proxy", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "Provisioning Rust host hello-loco.example.com on port 4040"
    assert script =~ "/etc/systemd/system/rust-hello-loco.service"
    assert script =~ "ExecStart=/bin/bash /opt/hello-loco/current/start.sh"
    assert script =~ "Environment=LOCO_ENV=production"
    assert script =~ "Environment=PORT=4040"
    assert script =~ "Environment=BINDING=127.0.0.1"
    assert script =~ "Environment=HOST=https://hello-loco.example.com"
    assert script =~ "reverse_proxy 127.0.0.1:4040"
  end

  test "build script installs Rust, builds a release binary, and starts Loco", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = Rust.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    assert script =~ "rustup"
    assert script =~ "cargo build --release"
    assert script =~ ~s|CARGO_TARGET_DIR="$HOME/.cache/cleat-rust/hello-loco"|
    assert script =~ "libssl-dev"
    assert script =~ "libsqlite3-dev"
    assert script =~ "/opt/hello-loco/releases/build"
    assert script =~ "sudo systemctl restart rust-hello-loco"
    assert script =~ "./bin/server start"
    assert script =~ "./bin/server db migrate"
    refute script =~ "mix release"
  end

  test "build script compiles a Loco frontend when frontend/package.json exists", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = Rust.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    assert script =~ "frontend/package.json"
    assert script =~ "npm ci"
    assert script =~ "npm run build"
  end

  test "manifest start_command and build_command win over detection" do
    app = %App{
      name: "Hello Loco",
      slug: "hello-loco",
      host: "hello-loco.example.com",
      runtime: "rust",
      port: 4040,
      release_path: "/opt/hello-loco",
      systemd_unit: "rust-hello-loco"
    }

    config = App.deploy_config(app)

    manifest = %AppManifest{
      runtime: "rust",
      build_command: "cargo build --release --features all",
      start_command: "./bin/server start --worker"
    }

    script = Rust.remote_build_script(nil, app, config, "abc", "/tmp/src.tar.gz", manifest)

    assert script =~ "cargo build --release --features all"
    assert script =~ "START_CMD='./bin/server start --worker'"
  end

  test "release_command replaces db migrate and runs before the restart", %{
    app: app,
    config: config
  } do
    manifest = %AppManifest{
      runtime: "rust",
      release_command: ["./bin/server db migrate && ./bin/server db seed"],
      release_timeout_s: 600
    }

    script = Rust.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    refute script =~ "Running loco db migrate"
    assert script =~ "Skipping db migrate (release_command is set"
    assert script =~ "Running release command (1/1)"

    assert occurrence(script, "Running release command") <
             occurrence(script, "Restarting rust-hello-loco")
  end

  defp occurrence(script, snippet) do
    {position, _length} = :binary.match(script, snippet)
    position
  end
end
