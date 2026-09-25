defmodule CleatDeploy.Deploy.SshEnvSyncTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.Ssh
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    {:ok, app, _webhook_status} =
      Apps.create_app(scope, %{
        name: "Trip Planner",
        slug: "trip-planner",
        github_repo: "puppe1990/trip-planner-ia-phx",
        host: "trip.gestaobem.com",
        server_id: server.id,
        systemd_unit: "trip_planner_ia",
        release_path: "/opt/trip_planner_ia",
        release_name: "trip_planner_ia"
      })

    %{app: app}
  end

  test "env_sync_enabled? is false without stored env vars", %{app: app} do
    app = Apps.get_app!(app.id)
    refute Ssh.env_sync_enabled?(app)
  end

  test "env_sync_enabled? is true when env vars exist", %{app: app} do
    {:ok, _} = Apps.put_env_var(app, "SECRET_KEY_BASE", "super-secret")
    app = Apps.get_app!(app.id)

    assert Ssh.env_sync_enabled?(app)
  end

  test "env_file_content includes PHX_HOST and stored vars", %{app: app} do
    {:ok, _} = Apps.put_env_var(app, "SECRET_KEY_BASE", "super-secret")
    {:ok, _} = Apps.put_env_var(app, "GEMINI_API_KEY", "gemini-key")
    app = Apps.get_app!(app.id)

    assert Ssh.env_file_content(app) ==
             """
             GEMINI_API_KEY=gemini-key
             PHX_HOST=trip.gestaobem.com
             SECRET_KEY_BASE=super-secret
             """
  end

  test "env_sync_script writes base64 env file on remote host", %{app: app} do
    {:ok, _} = Apps.put_env_var(app, "SECRET_KEY_BASE", "super-secret")
    app = Apps.get_app!(app.id)
    config = App.deploy_config(app)
    script = Ssh.env_sync_script(app, config)

    assert script =~ "Syncing environment from panel"
    assert script =~ "/etc/trip_planner_ia/env"
    assert script =~ Base.encode64(Ssh.env_file_content(app))
  end

  test "env_sync_script is empty when no env vars are stored", %{app: app} do
    app = Apps.get_app!(app.id)
    config = App.deploy_config(app)

    assert Ssh.env_sync_script(app, config) == ""
  end

  test "env_file_content of a branch carries the all-branches vars plus its own", %{app: app} do
    {:ok, _} = Apps.put_env_var(app, "SHARED", "all")
    {:ok, _} = Apps.put_env_var(app, "STAGING_ONLY", "yes", "staging")
    app = Apps.get_app!(app.id)

    assert Ssh.env_file_content(app, "main") ==
             """
             PHX_HOST=trip.gestaobem.com
             SHARED=all
             """

    assert Ssh.env_file_content(app, "staging") ==
             """
             PHX_HOST=trip.gestaobem.com
             SHARED=all
             STAGING_ONLY=yes
             """
  end

  test "a branch-scoped var overrides the same key scoped to all branches", %{app: app} do
    {:ok, _} = Apps.put_env_var(app, "BASE_URL", "https://prod.example.com")
    {:ok, _} = Apps.put_env_var(app, "BASE_URL", "https://staging.example.com", "staging")
    app = Apps.get_app!(app.id)

    staging = Ssh.env_file_content(app, "staging")
    assert staging =~ "BASE_URL=https://staging.example.com"
    refute staging =~ "prod.example.com"

    assert Ssh.env_file_content(app, "main") =~ "BASE_URL=https://prod.example.com"
  end

  test "env_sync_script writes the env file of the branch being deployed", %{app: app} do
    {:ok, _} = Apps.put_env_var(app, "SHARED", "all")
    {:ok, _} = Apps.put_env_var(app, "STAGING_ONLY", "yes", "staging")
    app = Apps.get_app!(app.id)

    staging_config = App.deploy_config(app) |> Map.put(:branch, "staging")
    script = Ssh.env_sync_script(app, staging_config)

    assert script =~ "/etc/trip_planner_ia/env"
    assert script =~ Base.encode64(Ssh.env_file_content(app, "staging"))
    refute script =~ "STAGING_ONLY=yes"
  end
end
