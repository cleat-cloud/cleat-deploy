defmodule CleatDeploy.Config.TursoConfigTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.Config.Turso

  test "builds LibSql URI config from Turso env vars" do
    env = fn
      "TURSO_DATABASE_URL" -> "libsql://my-db.turso.io"
      "TURSO_AUTH_TOKEN" -> "secret-token"
      "POOL_SIZE" -> "15"
      _ -> nil
    end

    assert [
             adapter: Ecto.Adapters.LibSql,
             migrator: Oban.Migrations.SQLite,
             uri: "libsql://my-db.turso.io",
             auth_token: "secret-token",
             pool_size: 15,
             busy_timeout: 10_000
           ] = Turso.repo_config(env)
  end

  test "falls back to local SQLite path when Turso URL is absent" do
    env = fn
      "DATABASE_PATH" -> "/var/data/cleat_deploy.db"
      "POOL_SIZE" -> nil
      _ -> nil
    end

    assert [
             adapter: Ecto.Adapters.LibSql,
             migrator: Oban.Migrations.SQLite,
             database: "/var/data/cleat_deploy.db",
             pool_size: 5,
             busy_timeout: 10_000,
             journal_mode: :wal
           ] = Turso.repo_config(env)
  end

  test "prefers DATABASE_PATH over Turso so a local cutover does not need the URL unset first" do
    env = fn
      "DATABASE_PATH" -> "/var/lib/cleat_deploy/cleat.db"
      "TURSO_DATABASE_URL" -> "libsql://my-db.turso.io"
      "TURSO_AUTH_TOKEN" -> "secret-token"
      "POOL_SIZE" -> "8"
      _ -> nil
    end

    config = Turso.repo_config(env)
    assert config[:database] == "/var/lib/cleat_deploy/cleat.db"
    assert config[:journal_mode] == :wal
    refute Keyword.has_key?(config, :uri)
  end

  test "raises when neither Turso nor DATABASE_PATH is set" do
    assert_raise RuntimeError, ~r/DATABASE_PATH or TURSO_DATABASE_URL/, fn ->
      Turso.repo_config(fn _ -> nil end)
    end
  end
end
