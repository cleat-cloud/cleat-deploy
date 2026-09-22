defmodule CleatDeploy.Deploy.AddonsTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deploy.Addons
  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "chatwoot",
        systemd_unit: "rails-chatwoot",
        release_path: "/opt/chatwoot",
        runtime: "rails"
      })

    %{app: app, scope: scope, server: server}
  end

  test "ensure/2 generates the credentials once and stores them as env vars", %{app: app} do
    manifest = %AppManifest{addons: ["postgres:pgvector", "redis"]}

    {addons, credentials} = Addons.ensure(app, manifest)

    assert addons == ["postgres:pgvector", "redis"]
    assert credentials["postgres:pgvector"].user == "cleat_chatwoot"
    assert credentials["postgres:pgvector"].database == "cleat_chatwoot"
    assert credentials["postgres:pgvector"].url =~ "postgres://cleat_chatwoot:"

    # Redis gets its own user and a database index derived from the app.
    assert credentials["redis"].user == "cleat_chatwoot"
    assert credentials["redis"].url =~ ~r|^redis://cleat_chatwoot:[^@]+@127\.0\.0\.1:6379/\d+$|

    env = Apps.env_map(app)
    assert env["DATABASE_URL"] == credentials["postgres:pgvector"].url
    assert env["REDIS_URL"] == credentials["redis"].url

    # Second deploy reuses what is already stored instead of rotating silently.
    {_, again} = Addons.ensure(app, manifest)
    assert again["postgres:pgvector"].password == credentials["postgres:pgvector"].password
    assert again["redis"].password == credentials["redis"].password
  end

  test "a foreign connection string is replaced by the addon's own", %{app: app} do
    {:ok, _} =
      Apps.put_env_var(app, "DATABASE_URL", "postgres://user:pw@db.example.com:5432/prod")

    {_, credentials} = Addons.ensure(app, %AppManifest{addons: ["postgres:pgvector"]})

    assert credentials["postgres:pgvector"].user == "cleat_chatwoot"
    assert Apps.env_map(app)["DATABASE_URL"] =~ "127.0.0.1:5432/cleat_chatwoot"
  end

  test "rotate/2 issues a new password", %{app: app} do
    addons = ["postgres:pgvector"]
    {_, before} = Addons.ensure(app, %AppManifest{addons: addons})

    {_, rotated} = Addons.rotate(app, addons)

    refute rotated["postgres:pgvector"].password == before["postgres:pgvector"].password
    assert Apps.env_map(app)["DATABASE_URL"] == rotated["postgres:pgvector"].url
  end

  test "provision_script/3 installs the datastores and creates app-scoped credentials", %{
    app: app
  } do
    manifest = %AppManifest{addons: ["postgres:pgvector", "redis"]}
    {_, credentials} = Addons.ensure(app, manifest)
    config = Map.put(App.deploy_config(app), :addon_credentials, credentials)

    script = Addons.provision_script(app, config, manifest)
    pg_password = credentials["postgres:pgvector"].password
    redis_password = credentials["redis"].password

    assert script =~ "apt-get install -y postgresql postgresql-contrib"
    assert script =~ "postgresql-${PG_VERSION}-pgvector"
    assert script =~ "shared_preload_libraries = 'pg_stat_statements'"
    assert script =~ "CREATE ROLE cleat_chatwoot LOGIN PASSWORD '#{pg_password}'"
    assert script =~ "CREATE DATABASE cleat_chatwoot OWNER cleat_chatwoot"
    assert script =~ "CREATE EXTENSION IF NOT EXISTS vector"
    assert script =~ "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
    assert script =~ "apt-get install -y redis-server"
    assert script =~ "ACL SETUSER cleat_chatwoot on >#{redis_password} ~* +@all"

    # Nothing happens without addons, or without credentials in the config.
    assert Addons.provision_script(app, config, %AppManifest{}) == ""
    assert Addons.provision_script(app, App.deploy_config(app), manifest) == ""
  end

  test "status_script/2 reports whether each datastore answers", %{app: app} do
    _ = Addons.ensure(app, %AppManifest{addons: ["postgres:pgvector", "redis"]})

    script = Addons.status_script(app, ["postgres:pgvector", "redis"])

    assert script =~ "systemctl is-active postgresql"
    assert script =~ "systemctl is-active redis-server"
    assert script =~ "SELECT 1 FROM pg_database WHERE datname = 'cleat_chatwoot'"
    assert script =~ "redis-cli ACL LIST"

    assert Addons.parse_status("""
             noise from ssh
             CLEAT addon postgres:pgvector ready cleat_chatwoot
             CLEAT addon redis inactive cleat_chatwoot
           """) == %{
             "postgres:pgvector" => %{state: "ready", detail: "cleat_chatwoot"},
             "redis" => %{state: "inactive", detail: "cleat_chatwoot"}
           }
  end

  test "teardown_script/2 drops the database, the role and the redis user", %{app: app} do
    _ = Addons.ensure(app, %AppManifest{addons: ["postgres:pgvector", "redis"]})

    postgres = Addons.teardown_script(app, "postgres:pgvector")
    assert postgres =~ "DROP DATABASE IF EXISTS cleat_chatwoot"
    assert postgres =~ "DROP ROLE IF EXISTS cleat_chatwoot"

    redis = Addons.teardown_script(app, "redis")
    assert redis =~ "ACL DELUSER cleat_chatwoot"
  end

  test "parse_credential/3 refuses URLs that are not ours", %{app: app} do
    assert {:ok, credential} =
             Addons.parse_credential(
               "postgres://cleat_x:pw@127.0.0.1:5432/cleat_x",
               "postgres:pgvector",
               app
             )

    assert credential.password == "pw"

    assert :error =
             Addons.parse_credential(
               "postgres://user:pw@db.example.com:5432/prod",
               "postgres:pgvector",
               app
             )

    assert :error = Addons.parse_credential("not a url", "redis", app)
  end
end
