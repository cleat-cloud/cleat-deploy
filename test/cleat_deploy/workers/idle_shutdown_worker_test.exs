defmodule CleatDeploy.Workers.IdleShutdownWorkerTest do
  use CleatDeploy.DataCase, async: false

  import Mox

  use Oban.Testing,
    repo: CleatDeploy.Repo,
    notifier: Oban.Notifiers.Isolated,
    testing: :manual

  alias CleatDeploy.Apps.IdleShutdownMock
  alias CleatDeploy.Settings
  alias CleatDeploy.TenancyFixtures
  alias CleatDeploy.Workers.IdleShutdownWorker

  setup :verify_on_exit!

  test "does not set Oban unique options that Turso cannot parse" do
    refute Keyword.get(IdleShutdownWorker.__opts__(), :unique)
  end

  test "is a no-op while the tenant has idle shutdown disabled" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    TenancyFixtures.app_fixture(scope, server, %{
      slug: "sleeper",
      idle_shutdown_enabled: true,
      systemd_unit: "phx-sleeper"
    })

    assert :ok = perform_job(IdleShutdownWorker, %{})
  end

  test "ignores apps that did not opt in" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    TenancyFixtures.app_fixture(scope, server, %{slug: "always-on", systemd_unit: "phx-always"})

    {:ok, _} =
      Settings.update_setting(scope, %{
        "idle_shutdown_enabled" => "true",
        "idle_shutdown_minutes" => "10"
      })

    assert :ok = perform_job(IdleShutdownWorker, %{})
  end

  test "stops idle apps of tenants that enabled the feature" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    TenancyFixtures.app_fixture(scope, server, %{
      slug: "sleeper",
      idle_shutdown_enabled: true,
      systemd_unit: "phx-sleeper"
    })

    {:ok, _} =
      Settings.update_setting(scope, %{
        "idle_shutdown_enabled" => "true",
        "idle_shutdown_minutes" => "10"
      })

    expect(IdleShutdownMock, :run, 2, fn _app, ["bash", "-c", script] ->
      if String.contains?(script, "systemctl stop") do
        assert script == "sudo systemctl stop 'phx-sleeper'"
        {:ok, ""}
      else
        {:ok, "CLEAT phx-sleeper 3600 active\n"}
      end
    end)

    assert :ok = perform_job(IdleShutdownWorker, %{})
  end

  test "leaves ready apps alone even when the tenant enabled the feature" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    TenancyFixtures.app_fixture(scope, server, %{
      slug: "sleeper",
      idle_shutdown_enabled: true,
      systemd_unit: "phx-sleeper"
    })

    {:ok, _} =
      Settings.update_setting(scope, %{
        "idle_shutdown_enabled" => "true",
        "idle_shutdown_minutes" => "10"
      })

    expect(IdleShutdownMock, :run, 1, fn _app, ["bash", "-c", script] ->
      refute String.contains?(script, "systemctl stop")
      {:ok, "CLEAT phx-sleeper 30 active\n"}
    end)

    assert :ok = perform_job(IdleShutdownWorker, %{})
  end
end
