defmodule Priv.Scripts.CutoverLocalSqliteEnvTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../../scripts/deploy/cutover-local-sqlite-env.py", __DIR__)

  test "comments Turso keys, writes DATABASE_PATH and re-enables the collector" do
    dir = System.tmp_dir!()
    env = Path.join(dir, "cleat-env-#{System.unique_integer([:positive])}")

    File.write!(env, """
    PORT=4000
    TURSO_DATABASE_URL=libsql://example.turso.io
    TURSO_AUTH_TOKEN=secret
    LOG_COLLECTOR_ENABLED=false
    """)

    {_, 0} = System.cmd("python3", [@script, "/var/lib/cleat_deploy/cleat.db", env])
    result = File.read!(env)

    assert result =~ "DATABASE_PATH=/var/lib/cleat_deploy/cleat.db"
    assert result =~ "# TURSO_DATABASE_URL=libsql://example.turso.io"
    assert result =~ "# TURSO_AUTH_TOKEN=secret"
    refute result =~ ~r/^TURSO_DATABASE_URL=/m
    assert result =~ "LOG_COLLECTOR_ENABLED=true"
    refute result =~ "LOG_COLLECTOR_ENABLED=false"
  end

  test "appends the collector flag when the env has none" do
    dir = System.tmp_dir!()
    env = Path.join(dir, "cleat-env-#{System.unique_integer([:positive])}")

    File.write!(env, """
    PORT=4000
    """)

    {_, 0} = System.cmd("python3", [@script, "/var/lib/cleat_deploy/cleat.db", env])
    result = File.read!(env)

    assert result =~ "DATABASE_PATH=/var/lib/cleat_deploy/cleat.db"
    assert result =~ "LOG_COLLECTOR_ENABLED=true"
  end
end
