defmodule CleatDeploy.Config.Turso do
  @moduledoc """
  Builds Ecto LibSQL repo configuration for production.
  """

  @doc """
  Returns keyword list suitable for `config :cleat_deploy, CleatDeploy.Repo, ...`.
  """
  def repo_config(env \\ &System.get_env/1) when is_function(env, 1) do
    database_path = blank_to_nil(env.("DATABASE_PATH"))
    turso_url = env.("TURSO_DATABASE_URL")
    turso_token = env.("TURSO_AUTH_TOKEN")
    pool_size = String.to_integer(env.("POOL_SIZE") || default_pool(database_path))

    cond do
      is_binary(database_path) ->
        [
          adapter: Ecto.Adapters.LibSql,
          migrator: Oban.Migrations.SQLite,
          database: database_path,
          pool_size: pool_size,
          busy_timeout: 10_000,
          journal_mode: :wal
        ]

      is_binary(turso_url) and String.starts_with?(turso_url, "libsql://") ->
        [
          adapter: Ecto.Adapters.LibSql,
          migrator: Oban.Migrations.SQLite,
          uri: turso_url,
          auth_token: turso_token,
          pool_size: pool_size,
          busy_timeout: 10_000
        ]

      true ->
        raise """
        environment variable DATABASE_PATH or TURSO_DATABASE_URL is missing.
        """
    end
  end

  defp default_pool(nil), do: "10"
  defp default_pool(_path), do: "5"

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
