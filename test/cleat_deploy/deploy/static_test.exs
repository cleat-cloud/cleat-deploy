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
    # Try the exact path, then the directory's index.html (so /pt/ serves
    # /pt/index.html), then the root index.html as the SPA fallback.
    assert script =~ "try_files {path} {path}/index.html /index.html"
    # Without an explicit Cache-Control, browsers apply heuristic freshness to
    # the ETag/Last-Modified pair and keep serving a previous deploy's page.
    assert script =~ ~s|header Cache-Control "no-cache"|
    # Static drops are usually previews; Google should stay out until the
    # operator turns indexing on.
    assert script =~ ~s|header X-Robots-Tag "noindex, nofollow"|
    assert script =~ "file_server"
    refute script =~ "reverse_proxy"
    refute script =~ "systemd"
  end

  test "indexable static apps omit X-Robots-Tag", %{app: app, config: config} do
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(%{app | indexable: true}, config, manifest)

    refute script =~ "X-Robots-Tag"
    assert script =~ ~s|header Cache-Control "no-cache"|
    assert script =~ "file_server"
  end

  test "IP hosts get an http:// static site", %{app: app} do
    app = %{app | host: "203.0.113.10"}
    config = App.deploy_config(app)
    manifest = AppManifest.resolve(nil, app)
    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "http://203.0.113.10 {"
    assert script =~ "root * /var/www/landing/current"
    assert script =~ "file_server"
  end

  test "build script installs node, builds, and publishes the output", %{app: app, config: config} do
    manifest = AppManifest.resolve(nil, app)
    script = Static.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    assert script =~ "npm ci || npm install"
    assert script =~ "npm run build"
    assert script =~ ~s|RELEASE_DIR="/var/www/landing/releases/$RELEASE_ID"|
    assert script =~ ~s|PUBLISH_DIR="$candidate"|
    assert script =~ "file_server"
    assert script =~ ~s|trap 'rm -rf "$BUILD_DIR"; rm -f /tmp/src.tar.gz' EXIT|
  end

  test "publishes into a fresh release and swaps current atomically", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = Static.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    # The active release is never reused or emptied in place: a second deploy
    # used to delete the files Caddy was serving before the copy finished.
    refute script =~ "releases/build"
    refute script =~ ~S|rm -rf "${RELEASE_DIR:?}"/*|
    assert script =~ ~s|RELEASE_ID="$(date -u +%Y%m%d%H%M%S)-abc123"|
    assert script =~ ~s|sudo cp -a "$PUBLISH_DIR"/. "$RELEASE_DIR"/|
    assert script =~ "Static release came out empty"
    assert script =~ "sudo ln -sfn \"$RELEASE_DIR\" /var/www/landing/current.next"
    assert script =~ "sudo mv -Tf /var/www/landing/current.next /var/www/landing/current"

    # Validation runs before the swap; the swap is a rename on the same FS.
    assert index_of(script, "Static release came out empty") < index_of(script, "current.next")
    assert index_of(script, "sudo cp -a") < index_of(script, "sudo mv -Tf")
  end

  test "drop publishes into a fresh release and swaps current atomically", %{
    app: app,
    config: config
  } do
    manifest = AppManifest.resolve(nil, app)
    script = Static.remote_drop_script(app, config, "sha", "/tmp/drop.tar.gz", manifest)

    refute script =~ "releases/build"
    refute script =~ ~S|rm -rf "${RELEASE_DIR:?}"/*|
    assert script =~ ~s|RELEASE_ID="$(date -u +%Y%m%d%H%M%S)-sha"|
    assert script =~ ~s|sudo cp -a "$BUILD_DIR"/. "$RELEASE_DIR"/|
    assert script =~ "sudo mv -Tf /var/www/landing/current.next /var/www/landing/current"
    assert script =~ "tail -n +5"
  end

  test "sanitizes the deployment sha in the release directory name", %{app: app, config: config} do
    manifest = AppManifest.resolve(nil, app)
    script = Static.remote_build_script(nil, app, config, "a b/c", "/tmp/src.tar.gz", manifest)

    assert script =~ ~s|RELEASE_ID="$(date -u +%Y%m%d%H%M%S)-a-b-c"|
    refute script =~ ~s|RELEASE_ID="$(date -u +%Y%m%d%H%M%S)-a b/c"|
  end

  test "drop script removes its build dir and tarball", %{app: app, config: config} do
    manifest = AppManifest.resolve(nil, app)
    script = Static.remote_drop_script(app, config, "sha", "/tmp/drop.tar.gz", manifest)

    assert script =~ ~s|trap 'rm -rf "$BUILD_DIR"; rm -f /tmp/drop.tar.gz' EXIT|
  end

  test "build script falls back to the repo root for plain HTML folders" do
    app = %App{
      name: "Plain",
      slug: "plain",
      host: "plain.example.com",
      runtime: "static",
      release_path: "/var/www/plain"
    }

    config = App.deploy_config(app)
    manifest = %AppManifest{runtime: "static"}
    script = Static.remote_build_script(nil, app, config, "sha", "/tmp/s.tar.gz", manifest)

    assert script =~ ~s|PUBLISH_DIR="."|
    assert script =~ "index.html at the repo root"
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

  defp index_of(script, needle) do
    {index, _length} = :binary.match(script, needle)
    index
  end
end
