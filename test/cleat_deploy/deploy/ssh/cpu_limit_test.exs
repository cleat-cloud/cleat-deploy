defmodule CleatDeploy.Deploy.Ssh.CpuLimitTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.{AppManifest, Golang, Node, Ssh}
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    %{scope: scope, server: server}
  end

  test "snippet pins compile to 150% CPUQuota so a CX33 keeps Caddy schedulable" do
    snippet = Ssh.CpuLimit.snippet()

    assert snippet =~ "cleat_cpu_limit()"
    assert snippet =~ "CPUQuota=150%"
    assert snippet =~ "Nice=10"
    assert snippet =~ "systemd-run"
    assert Ssh.CpuLimit.wrap("mix compile") == "cleat_cpu_limit mix compile"
  end

  test "phoenix compile/release runs inside the CPU cap", %{scope: scope, server: server} do
    {:ok, app, _} =
      Apps.create_app(scope, %{
        name: "Open Drive",
        slug: "open-drive",
        github_repo: "puppe1990/OpenDrive",
        host: "drive.gestaobem.com",
        server_id: server.id
      })

    app = Apps.get_app!(scope, app.id)
    config = App.deploy_config(app) |> Map.put(:ssh_user, server.ssh_user)
    manifest = AppManifest.resolve(nil, app)
    runtime = %{packages: [], post_install: []}

    script =
      Ssh.Phoenix.phoenix_remote_build_script(
        server,
        app,
        config,
        "abc1234",
        "/tmp/src.tar.gz",
        runtime,
        manifest
      )

    assert script =~ "CPUQuota=150%"
    assert script =~ "cleat_cpu_limit mix compile"
    assert script =~ "cleat_cpu_limit mix release --overwrite"
  end

  test "node build runs inside the CPU cap", %{scope: scope, server: server} do
    {:ok, app, _} =
      Apps.create_app(scope, %{
        name: "Landing",
        slug: "landing",
        github_repo: "gestao-bem/gestao-bem-landing",
        host: "gestaobem.com",
        runtime: "node",
        server_id: server.id
      })

    app = Apps.get_app!(scope, app.id)
    config = App.deploy_config(app)
    manifest = AppManifest.resolve(nil, app)
    script = Node.remote_build_script(nil, app, config, "abc123", "/tmp/src.tar.gz", manifest)

    assert script =~ "CPUQuota=150%"
    assert script =~ "cleat_cpu_limit npm run build"
  end

  test "go build runs inside the CPU cap", %{scope: scope, server: server} do
    {:ok, app, _} =
      Apps.create_app(scope, %{
        name: "Atelie",
        slug: "atelie",
        github_repo: "puppe1990/atelie",
        host: "atelie.gestaobem.com",
        runtime: "golang",
        server_id: server.id
      })

    app = Apps.get_app!(scope, app.id)
    config = App.deploy_config(app)
    manifest = %{AppManifest.resolve(nil, app) | runtime: "golang", binaries: ["server"]}

    script =
      Golang.remote_build_script(server, app, config, "abc1234", "/tmp/src.tar.gz", manifest)

    assert script =~ "CPUQuota=150%"
    assert script =~ "cleat_cpu_limit go build -o bin/server"
  end
end
