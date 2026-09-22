defmodule CleatDeploy.Apps.RuntimeControlTest do
  use CleatDeploy.DataCase, async: false

  import Mox

  alias CleatDeploy.Apps.RuntimeControl
  alias CleatDeploy.Apps.RuntimeControlMock
  alias CleatDeploy.TenancyFixtures

  setup :verify_on_exit!

  test "hibernate stops the unit and confirms it went inactive" do
    app = app_fixture()

    expect(RuntimeControlMock, :run, fn subject, ["bash", "-c", script] ->
      assert subject.id == app.id
      assert script =~ "sudo systemctl stop 'phx-sleeper'"
      assert script =~ "systemctl is-active 'phx-sleeper'"
      {:ok, "state=inactive\n"}
    end)

    assert RuntimeControl.hibernate(app) == :ok
  end

  test "wake starts the unit and confirms it is active" do
    app = app_fixture()

    expect(RuntimeControlMock, :run, fn _subject, ["bash", "-c", script] ->
      assert script =~ "sudo systemctl start 'phx-sleeper'"
      {:ok, "state=active\n"}
    end)

    assert RuntimeControl.wake(app) == :ok
  end

  test "reports the unit state when the action did not take effect" do
    app = app_fixture()

    expect(RuntimeControlMock, :run, fn _subject, _argv -> {:ok, "state=active\n"} end)

    assert RuntimeControl.hibernate(app) == {:error, "unit phx-sleeper is active"}
  end

  test "surfaces ssh failures" do
    app = app_fixture()

    expect(RuntimeControlMock, :run, fn _subject, _argv ->
      {:error, "ssh: connect to host timed out"}
    end)

    assert RuntimeControl.wake(app) == {:error, "ssh: connect to host timed out"}
  end

  test "refuses static apps, which have no unit to control" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        runtime: "static",
        github_repo: "",
        systemd_unit: nil
      })

    assert RuntimeControl.hibernate(app) == {:error, "app has no systemd unit to control"}
  end

  test "says the next request starts an app whose deploy armed the wake" do
    app = app_fixture()

    assert RuntimeControl.wake_hint(app) ==
             "It only comes back with the Wake up button or on the next deploy."

    {:ok, armed} = CleatDeploy.Apps.record_deploy_manifest(app, %{wake: true})

    assert RuntimeControl.wake_hint(armed) ==
             "It is armed for wake-on-request, so the next request starts it again automatically."
  end

  test "does not promise auto wake for an app that only has the flag on" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "sleeper",
        host: "sleeper.example.com",
        systemd_unit: "phx-sleeper"
      })

    {:ok, app} =
      CleatDeploy.Apps.update_app_settings(scope, app, %{"idle_shutdown_enabled" => true})

    assert app.idle_shutdown_enabled
    assert RuntimeControl.wake_hint(app) =~ "only comes back with the Wake up button"
  end

  defp app_fixture do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    TenancyFixtures.app_fixture(scope, server, %{
      slug: "sleeper",
      host: "sleeper.example.com",
      systemd_unit: "phx-sleeper"
    })
  end
end
