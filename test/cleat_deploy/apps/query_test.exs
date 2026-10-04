defmodule CleatDeploy.Apps.QueryTest do
  use CleatDeploy.DataCase, async: false

  import Mox

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.Query
  alias CleatDeploy.Apps.QueryMock
  alias CleatDeploy.TenancyFixtures

  setup :verify_on_exit!

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    %{scope: scope, server: server, app: app}
  end

  test "rejects writes, multiple statements and empty SQL" do
    assert {:error, :invalid_sql, message} = Query.validate("INSERT INTO users VALUES (1)")
    assert message =~ "read-only"

    assert {:error, :invalid_sql, _} = Query.validate("SELECT 1; DROP TABLE users")
    assert {:error, :invalid_sql, _} = Query.validate("   ")

    assert {:error, :invalid_sql, _} =
             Query.validate("WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x")

    assert {:error, :invalid_sql, _} = Query.validate("SELECT * INTO tmp FROM users")
    assert {:error, :invalid_sql, _} = Query.validate("PRAGMA journal_mode=WAL")
  end

  test "accepts SELECT, WITH, EXPLAIN, SHOW and read PRAGMA" do
    assert {:ok, "SELECT"} = Query.validate("SELECT * FROM users")
    assert {:ok, "WITH"} = Query.validate("WITH x AS (SELECT 1) SELECT * FROM x")
    assert {:ok, "EXPLAIN"} = Query.validate("EXPLAIN SELECT 1")
    assert {:ok, "SHOW"} = Query.validate("SHOW search_path")
    assert {:ok, "PRAGMA"} = Query.validate("PRAGMA table_info(users)")
    assert {:ok, "SELECT"} = Query.validate("select id from users;")
  end

  test "resolves postgres, sqlite and missing datastores", %{scope: scope, app: app} do
    {:ok, _} =
      Apps.put_env_var(
        app,
        "DATABASE_URL",
        "postgres://cleat_app:secret@127.0.0.1:5432/cleat_app"
      )

    assert {:ok, {:postgres, url}} = Query.target(Apps.get_app!(scope, app.id))
    assert String.starts_with?(url, "postgres://")

    {:ok, _} = Apps.put_env_var(app, "DATABASE_URL", "file:/opt/apps/app/data/app.db")

    assert {:ok, {:sqlite, "/opt/apps/app/data/app.db"}} =
             Query.target(Apps.get_app!(scope, app.id))

    :ok = Apps.delete_env_var(app, "DATABASE_URL")
    {:ok, _} = Apps.put_env_var(app, "DATABASE_PATH", "/var/lib/app/data.sqlite")

    assert {:ok, {:sqlite, "/var/lib/app/data.sqlite"}} =
             Query.target(Apps.get_app!(scope, app.id))

    :ok = Apps.delete_env_var(app, "DATABASE_PATH")
    {:ok, _} = Apps.put_env_var(app, "TURSO_DATABASE_URL", "libsql://example.turso.io")
    assert {:error, :unsupported_database} = Query.target(Apps.get_app!(scope, app.id))

    :ok = Apps.delete_env_var(app, "TURSO_DATABASE_URL")
    assert {:error, :no_database} = Query.target(Apps.get_app!(scope, app.id))
  end

  test "runs a SELECT through the runner and truncates extra rows", %{scope: scope, app: app} do
    {:ok, _} = Apps.put_env_var(app, "DATABASE_PATH", "/opt/apps/demo/data.db")
    app = Apps.get_app!(scope, app.id)

    expect(QueryMock, :run, fn received, ["bash", "-lc", script] ->
      assert received.id == app.id
      assert script =~ "sqlite3"
      assert script =~ "mode=ro"
      refute script =~ "INSERT"
      {:ok, "id,name\n1,ada\n2,grace\n3,evelyn\n"}
    end)

    assert {:ok, result} = Query.run(scope, app, "SELECT * FROM users", limit: 2)
    assert result.engine == "sqlite"
    assert result.columns == ["id", "name"]
    assert result.rows == [["1", "ada"], ["2", "grace"]]
    assert result.truncated
    assert result.slug == app.slug
  end

  test "redacts connection strings from runner errors", %{scope: scope, app: app} do
    {:ok, _} =
      Apps.put_env_var(
        app,
        "DATABASE_URL",
        "postgres://cleat_app:s3cret@127.0.0.1:5432/cleat_app"
      )

    app = Apps.get_app!(scope, app.id)

    expect(QueryMock, :run, fn received, _argv ->
      assert received.id == app.id
      {:error, "psql: postgres://cleat_app:s3cret@127.0.0.1:5432/cleat_app failed"}
    end)

    assert {:error, :query_failed, message} = Query.run(scope, app, "SELECT 1")
    refute message =~ "s3cret"
    assert message =~ "[redacted]"
  end

  test "does not query another tenant's app", %{app: app} do
    other = TenancyFixtures.scope_fixture()
    assert {:error, :not_found} = Query.run(other, app, "SELECT 1")
  end
end
