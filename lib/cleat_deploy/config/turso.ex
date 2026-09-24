defmodule CleatDeploy.Config.Turso do
  @moduledoc """
  Builds Ecto LibSQL repo configuration for production.
  """

  @doc """
  Returns keyword list suitable for `config :cleat_deploy, CleatDeploy.Repo, ...`.
  """
  def repo_config(env \\ &System.get_env/1) when is_function(env, 1) do
    turso_url = env.("TURSO_DATABASE_URL")
    turso_token = env.("TURSO_AUTH_TOKEN")
    pool_size = String.to_integer(env.("POOL_SIZE") || "10")

    if turso_url && String.starts_with?(turso_url, "libsql://") do
      [
        adapter: Ecto.Adapters.LibSql,
        migrator: Oban.Migrations.SQLite,
        uri: turso_url,
        auth_token: turso_token,
        pool_size: pool_size,
        busy_timeout: 10_000
      ]
    else
      database_path =
        env.("DATABASE_PATH") ||
          raise """
          environment variable DATABASE_PATH or TURSO_DATABASE_URL is missing.
          """

      [
        adapter: Ecto.Adapters.LibSql,
        migrator: Oban.Migrations.SQLite,
        database: database_path,
        pool_size: String.to_integer(env.("POOL_SIZE") || "5"),
        busy_timeout: 10_000
      ]
    end
  end
end
