defmodule CleatDeploy.Deploy.TeardownTest do
  use CleatDeploy.DataCase, async: true

  alias CleatDeploy.Deploy.Teardown
  alias CleatDeploy.TenancyFixtures

  test "script stops the unit and removes the release" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "cifra",
        host: "finops.gestaobem.com",
        systemd_unit: "cifra",
        release_path: "/opt/cifra"
      })

    script = Teardown.script(app)

    assert script =~ ~s(UNIT='cifra')
    assert script =~ ~s(RELEASE='/opt/cifra')
    assert script =~ ~s(HOST='finops.gestaobem.com')
    assert script =~ ~s(systemctl stop)
    assert script =~ ~s(rm -rf "$RELEASE")
    assert script =~ "CLEAT_REMOVE_HOST="
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
  end

  test "remove_unit/2 is a no-op when the deploy runner is not SSH" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)

    assert Teardown.remove_unit(app, "phx-lumina") == :ok
  end
end
