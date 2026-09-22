defmodule CleatDeploy.SettingsTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Settings
  alias CleatDeploy.Settings.Setting
  alias CleatDeploy.TenancyFixtures

  test "defaults to disabled with a 60 minute window and no row" do
    scope = TenancyFixtures.scope_fixture()
    setting = Settings.get_setting(scope)

    refute setting.idle_shutdown_enabled
    assert setting.idle_shutdown_minutes == 60
    assert setting.id == nil
    assert Repo.aggregate(Setting, :count) == 0
  end

  test "saves and updates the tenant settings on a single row" do
    scope = TenancyFixtures.scope_fixture()

    assert {:ok, setting} =
             Settings.update_setting(scope, %{
               "idle_shutdown_enabled" => "true",
               "idle_shutdown_minutes" => "30"
             })

    assert setting.idle_shutdown_enabled
    assert setting.idle_shutdown_minutes == 30

    assert {:ok, updated} =
             Settings.update_setting(scope, %{
               "idle_shutdown_enabled" => "false",
               "idle_shutdown_minutes" => "45"
             })

    assert updated.id == setting.id
    refute updated.idle_shutdown_enabled

    saved = Settings.get_setting(scope)
    assert saved.idle_shutdown_minutes == 45
    refute saved.idle_shutdown_enabled
    assert Repo.aggregate(Setting, :count) == 1
  end

  test "rejects windows outside the supported range" do
    scope = TenancyFixtures.scope_fixture()

    assert {:error, changeset} =
             Settings.update_setting(scope, %{
               "idle_shutdown_enabled" => "true",
               "idle_shutdown_minutes" => "1"
             })

    assert %{idle_shutdown_minutes: ["must be greater than or equal to 5"]} =
             errors_on(changeset)

    assert {:error, changeset} =
             Settings.update_setting(scope, %{
               "idle_shutdown_enabled" => "true",
               "idle_shutdown_minutes" => "999999"
             })

    assert %{idle_shutdown_minutes: ["must be less than or equal to 43200"]} =
             errors_on(changeset)

    assert Repo.aggregate(Setting, :count) == 0
  end

  test "list_idle_shutdown returns only tenants that enabled the feature" do
    enabled = TenancyFixtures.scope_fixture()
    disabled = TenancyFixtures.scope_fixture()

    {:ok, _} =
      Settings.update_setting(enabled, %{
        "idle_shutdown_enabled" => "true",
        "idle_shutdown_minutes" => "20"
      })

    {:ok, _} =
      Settings.update_setting(disabled, %{
        "idle_shutdown_enabled" => "false",
        "idle_shutdown_minutes" => "20"
      })

    assert Settings.list_idle_shutdown() == [{enabled.tenant.id, 20}]
  end
end
