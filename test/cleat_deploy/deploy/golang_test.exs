defmodule CleatDeploy.Deploy.GolangTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.{AppManifest, Golang, ServerProvision}
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope, %{ssh_user: "ubuntu"})

    {:ok, app, _} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Ateliê",
        slug: "atelie",
        github_repo: "puppe1990/atelie",
        host: "atelie.gestaobem.com",
        port: 4020,
        runtime: "golang",
        systemd_unit: "atelie",
        release_path: "/opt/atelie",
        server_id: server.id
      })

    config =
      app
      |> App.deploy_config()
      |> Map.put(:ssh_user, server.ssh_user)

    %{app: app, config: config, server: server}
  end

  test "golang systemd unit starts bin/server instead of an OTP release", %{
    app: app,
    config: config
  } do
    manifest = %{
      AppManifest.resolve(nil, app)
      | runtime: "golang",
        binaries: ["server", "worker"]
    }

    script = ServerProvision.provision_script(app, config, manifest)

    assert script =~ "ExecStart=/opt/atelie/current/bin/server"
    refute script =~ "bin/atelie start"
    assert script =~ "User=ubuntu"
    assert script =~ "WorkingDirectory=/opt/atelie/current"
    assert script =~ "/etc/systemd/system/atelie-worker.service"
    assert script =~ "ExecStart=/opt/atelie/current/bin/worker"
    assert script =~ "atelie.gestaobem.com {"
  end

  test "golang remote build installs Go and builds linux binaries", %{
    app: app,
    config: config,
    server: server
  } do
    manifest = %{
      AppManifest.resolve(nil, app)
      | runtime: "golang",
        binaries: ["server", "worker"]
    }

    script =
      Golang.remote_build_script(server, app, config, "abc1234", "/tmp/src.tar.gz", manifest)

    assert script =~ "Installing Go"
    assert script =~ "1.26.4"
    assert script =~ "go build -o bin/server"
    assert script =~ "go build -o bin/worker"
    assert script =~ "/opt/atelie/releases/build"
    assert script =~ "systemctl restart atelie"
    assert script =~ "systemctl restart atelie-worker"
    refute script =~ "mix release"
  end

  test "release command runs after publishing and before the units restart", %{
    app: app,
    config: config,
    server: server
  } do
    manifest = %{
      AppManifest.resolve(nil, app)
      | runtime: "golang",
        binaries: ["server", "worker"],
        release_command: ["/opt/atelie/current/bin/server migrate"]
    }

    script =
      Golang.remote_build_script(server, app, config, "abc1234", "/tmp/src.tar.gz", manifest)

    assert script =~ "Running release command (1/1)"
    assert occurrence(script, "Running release command") < occurrence(script, "Restarting atelie")
  end

  defp occurrence(script, snippet) do
    {position, _length} = :binary.match(script, snippet)
    position
  end
end
