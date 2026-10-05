defmodule CleatDeploy.Apps.EnvApplyTest do
  use CleatDeploy.DataCase, async: false

  import Mox

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.EnvApply
  alias CleatDeploy.Apps.RuntimeControlMock
  alias CleatDeploy.Deploy.Ssh
  alias CleatDeploy.TenancyFixtures

  setup :verify_on_exit!

  test "writes the env file and restarts units that are already active" do
    app = node_app()
    {:ok, _} = Apps.put_env_var(app, "GOWA_DEVICE_ID", "ednasp1")
    app = Apps.get_app!(app.id)
    encoded = Base.encode64(Ssh.env_file_content(app, app.branch))

    expect(RuntimeControlMock, :run, fn subject, ["bash", "-c", script] ->
      assert subject.id == app.id
      assert script =~ "sudo tee /etc/gestao-bem-crm/env"
      assert script =~ encoded
      assert script =~ "systemctl is-active --quiet 'node-gestao-bem-crm'"
      assert script =~ "sudo systemctl restart 'node-gestao-bem-crm'"
      {:ok, ""}
    end)

    assert EnvApply.apply(app) == :ok
  end

  test "does not wake a hibernated unit: writes the file and skips restart when inactive" do
    app = node_app()
    {:ok, _} = Apps.put_env_var(app, "GOWA_DEVICE_ID", "ednasp1")

    expect(RuntimeControlMock, :run, fn _subject, ["bash", "-c", script] ->
      assert script =~ "sudo tee /etc/gestao-bem-crm/env"
      assert script =~ "if systemctl is-active --quiet 'node-gestao-bem-crm'"
      assert script =~ "sudo systemctl restart 'node-gestao-bem-crm'"
      assert script =~ "/var/lib/cleat/stamps/node-gestao-bem-crm.stamp"
      assert script =~ "hibernated"
      {:ok, ""}
    end)

    assert EnvApply.apply(app) == :ok
  end

  test "reset-failed and starts a crashed unit instead of leaving it down" do
    app = node_app()
    {:ok, _} = Apps.put_env_var(app, "PORT", ":4000")

    expect(RuntimeControlMock, :run, fn _subject, ["bash", "-c", script] ->
      assert script =~ "systemctl is-failed --quiet 'node-gestao-bem-crm'"
      assert script =~ "sudo systemctl reset-failed 'node-gestao-bem-crm'"
      assert script =~ "sudo systemctl start 'node-gestao-bem-crm'"
      assert script =~ "NRestarts"
      assert script =~ "http://127.0.0.1:#{app.port}/"
      assert script =~ "journalctl -u 'node-gestao-bem-crm'"
      {:ok, ""}
    end)

    assert EnvApply.apply(app) == :ok
  end

  test "skips static apps, which have no unit and no env file to apply" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        runtime: "static",
        github_repo: "",
        systemd_unit: nil
      })

    assert EnvApply.apply(app) == :ok
  end

  test "does not touch the running app when the var is scoped to another branch" do
    app = node_app()
    {:ok, _} = Apps.put_env_var(app, "STAGING_ONLY", "yes", "staging")

    assert EnvApply.apply(app, "staging") == :ok
  end

  test "surfaces ssh failures after the panel already stored the var" do
    app = node_app()
    {:ok, _} = Apps.put_env_var(app, "GOWA_DEVICE_ID", "ednasp1")

    expect(RuntimeControlMock, :run, fn _subject, _argv ->
      {:error, "ssh: connect to host timed out"}
    end)

    assert EnvApply.apply(app) == {:error, "ssh: connect to host timed out"}
  end

  test "bounds the apply when the remote command never returns" do
    app = node_app()
    {:ok, _} = Apps.put_env_var(app, "GOWA_DEVICE_ID", "ednasp1")

    Application.put_env(:cleat_deploy, :env_apply_timeout_ms, 50)
    on_exit(fn -> Application.delete_env(:cleat_deploy, :env_apply_timeout_ms) end)

    expect(RuntimeControlMock, :run, fn _subject, _argv ->
      Process.sleep(500)
      {:ok, ""}
    end)

    assert EnvApply.apply(app) == {:error, :timeout}
  end

  test "restarts extra units of a golang app when they are active" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "gowa",
        host: "gowa.apps.gestaobem.com",
        runtime: "golang",
        systemd_unit: "gowa",
        release_path: "/opt/gowa"
      })

    {:ok, _} = Apps.put_env_var(app, "CHATWOOT_TOKEN", "x")

    expect(RuntimeControlMock, :run, fn _subject, ["bash", "-c", script] ->
      assert script =~ "sudo systemctl restart 'gowa'"
      assert script =~ "sudo systemctl restart 'gowa-worker'"
      assert script =~ "systemctl cat --quiet 'gowa-worker'"
      {:ok, ""}
    end)

    assert EnvApply.apply(app) == :ok
  end

  test "skips a ghost unit that was never provisioned" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "radar-pncp",
        host: "radar.apps.gestaobem.com",
        runtime: "golang",
        systemd_unit: "radar-pncp",
        release_path: "/opt/radar-pncp"
      })

    {:ok, _} = Apps.put_env_var(app, "PNCP_KEY", "x")
    {:ok, app} = Apps.record_deploy_manifest(app, %{units: []})

    expect(RuntimeControlMock, :run, fn _subject, ["bash", "-c", script] ->
      assert script =~ "systemctl cat --quiet 'radar-pncp'"
      refute script =~ "radar-pncp-worker"
      {:ok, ""}
    end)

    assert EnvApply.apply(app) == :ok
  end

  defp node_app do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    TenancyFixtures.app_fixture(scope, server, %{
      slug: "gestao-bem-crm",
      host: "crm.apps.gestaobem.com",
      runtime: "node",
      systemd_unit: "node-gestao-bem-crm",
      release_path: "/opt/gestao-bem-crm",
      branch: "main"
    })
  end
end
