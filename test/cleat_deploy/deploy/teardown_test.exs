defmodule CleatDeploy.Deploy.TeardownTest do
  use CleatDeploy.DataCase, async: true

  alias CleatDeploy.Deploy.Teardown
  alias CleatDeploy.TenancyFixtures

  test "script removes every unit of the app, the stamps and the release" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "cifra",
        host: "finops.gestaobem.com",
        systemd_unit: "cifra",
        release_path: "/opt/cifra"
      })
      |> Map.put(:deploy_manifest, %{"units" => ["worker"], "addons" => []})

    script = Teardown.script(app)

    assert script =~ ~s(UNIT='cifra')
    assert script =~ ~s(UNIT='cifra-worker')
    assert script =~ ~s(RELEASE='/opt/cifra')
    assert script =~ ~s(HOST='finops.gestaobem.com')
    assert script =~ ~s(systemctl stop "$UNIT")
    assert script =~ ~s(rm -f "/etc/systemd/system/${UNIT}.service")
    assert script =~ ~s(rm -rf "$RELEASE")
    assert script =~ ~s(rm -f '/var/lib/cleat/stamps/cifra.stamp')
    assert script =~ ~s(rm -f '/var/lib/cleat/stamps/cifra-worker.stamp')
    assert script =~ "CLEAT_REMOVE_HOST="
  end

  test "script drops the managed addon data when the app is deleted" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "chatwoot",
        systemd_unit: "rails-chatwoot"
      })
      |> Map.put(:deploy_manifest, %{"units" => [], "addons" => ["postgres:pgvector", "redis"]})

    {:ok, _} =
      CleatDeploy.Apps.put_env_var(
        app,
        "DATABASE_URL",
        "postgres://cleat_chatwoot:pw@127.0.0.1:5432/cleat_chatwoot"
      )

    {:ok, _} =
      CleatDeploy.Apps.put_env_var(
        app,
        "REDIS_URL",
        "redis://cleat_chatwoot:pw@127.0.0.1:6379/3"
      )

    script = Teardown.script(app)

    assert script =~ "DROP DATABASE IF EXISTS cleat_chatwoot"
    assert script =~ "DROP ROLE IF EXISTS cleat_chatwoot"
    assert script =~ "ACL DELUSER cleat_chatwoot"
  end

  test "run/1 is a no-op when the deploy runner is not SSH" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)

    assert Teardown.run(app) == :ok
  end

  test "remove_host_script targets the given host" do
    script = Teardown.remove_host_script("old.sites.gestaobem.com")

    assert script =~ "CLEAT_REMOVE_HOST='old.sites.gestaobem.com'"
    assert script =~ "reload caddy"
  end

  test "remove_host/2 is a no-op when the deploy runner is not SSH" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)

    assert Teardown.remove_host(app, "old.sites.gestaobem.com") == :ok
  end

  test "remove_unit_script stops, disables and deletes the unit" do
    script = Teardown.remove_unit_script("phx-lumina")

    assert script =~ ~s(UNIT='phx-lumina')
    assert script =~ ~s(systemctl stop "$UNIT")
    assert script =~ ~s(systemctl disable "$UNIT")
    assert script =~ ~s(rm -f "/etc/systemd/system/${UNIT}.service")
    assert script =~ ~s(systemctl reset-failed "$UNIT")
    assert script =~ ~s(rm -f '/var/lib/cleat/stamps/phx-lumina.stamp')
  end

  test "remove_unit/2 is a no-op when the deploy runner is not SSH" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)

    assert Teardown.remove_unit(app, "phx-lumina") == :ok
  end
end
