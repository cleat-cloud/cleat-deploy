defmodule CleatDeploy.Apps.Query do
  @moduledoc """
  Read-only SQL against an app's Postgres addon or local SQLite file.

  The statement is validated here, then executed on the app's VM over SSH
  (or locally when the panel shares the host). Writes never leave this module.
  """

  alias CleatDeploy.Accounts.Scope
  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.Observability.Redact
  alias CleatDeploy.Repo

  @callback run(App.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}

  @max_sql_bytes 16_384
  @default_limit 50
  @max_limit 200
  @timeout_ms 15_000
  @statement_timeout_ms 5_000
  @read_keywords ~w(SELECT WITH EXPLAIN SHOW PRAGMA TABLE VALUES)
  @write_tokens ~w(
    INSERT UPDATE DELETE DROP ALTER CREATE COPY GRANT REVOKE TRUNCATE VACUUM
    REINDEX ATTACH DETACH REPLACE LOAD
  )

  @doc "First keyword when `sql` is a single read-only statement."
  def validate(sql) when is_binary(sql) do
    cond do
      byte_size(sql) > @max_sql_bytes ->
        {:error, :invalid_sql, "SQL is longer than #{@max_sql_bytes} bytes"}

      true ->
        stripped = strip_comments(sql)

        cond do
          String.trim(stripped) == "" ->
            {:error, :invalid_sql, "SQL is empty"}

          extra_statement?(stripped) ->
            {:error, :invalid_sql, "one statement only"}

          true ->
            body = stripped |> String.trim() |> String.trim_trailing(";") |> String.trim()
            keyword = first_keyword(body)

            cond do
              keyword not in @read_keywords ->
                {:error, :invalid_sql,
                 "read-only queries only (SELECT, WITH, EXPLAIN, SHOW, PRAGMA)"}

              write_token?(body) ->
                {:error, :invalid_sql,
                 "read-only queries only (SELECT, WITH, EXPLAIN, SHOW, PRAGMA)"}

              keyword == "PRAGMA" and String.contains?(body, "=") ->
                {:error, :invalid_sql, "PRAGMA assignment is not allowed"}

              true ->
                {:ok, keyword}
            end
        end
    end
  end

  def validate(_), do: {:error, :invalid_sql, "SQL is empty"}

  @doc "Postgres URL or absolute SQLite path for the app."
  def target(%App{} = app) do
    env = Apps.env_map(app)

    cond do
      postgres?(env["DATABASE_URL"]) ->
        {:ok, {:postgres, env["DATABASE_URL"]}}

      path = sqlite_path(env) ->
        if safe_sqlite_path?(path) do
          {:ok, {:sqlite, path}}
        else
          {:error, :unsafe_path}
        end

      remote_libsql?(env["DATABASE_URL"]) or remote_libsql?(env["TURSO_DATABASE_URL"]) ->
        {:error, :unsupported_database}

      true ->
        {:error, :no_database}
    end
  end

  @doc """
  Runs `sql` against `app`'s datastore.

  `opts` may include `:limit` (1..#{@max_limit}, default #{@default_limit}).
  """
  def run(scope, app, sql, opts \\ [])

  def run(%Scope{tenant: tenant}, %App{tenant_id: tenant_id} = app, sql, opts)
      when tenant.id == tenant_id do
    app = Repo.preload(app, [:server, :env_vars], force: true)
    limit = clamp_limit(Keyword.get(opts, :limit, @default_limit))

    with {:ok, keyword} <- validate(sql),
         {:ok, store} <- target(app) do
      execute(app, store, sql, keyword, limit)
    end
  end

  def run(%Scope{}, %App{}, _sql, _opts), do: {:error, :not_found}

  defp execute(app, store, sql, keyword, limit) do
    body = sql |> strip_comments() |> String.trim() |> String.trim_trailing(";") |> String.trim()
    limited = maybe_limit(body, keyword, limit)
    script = remote_script(store, limited)

    case yield_run(app, ["bash", "-lc", script]) do
      {:ok, output} ->
        {:ok, pack(app, store, parse_csv(output), limit)}

      {:error, reason} ->
        {:error, :query_failed, format_error(reason)}
    end
  end

  defp yield_run(app, argv) do
    task = Task.async(fn -> client().run(app, argv) end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, "query timed out after #{div(@timeout_ms, 1000)}s"}
    end
  end

  defp pack(app, {engine, _}, %{columns: columns, rows: rows}, limit) do
    truncated = length(rows) > limit

    %{
      app_id: app.id,
      slug: app.slug,
      engine: engine_name(engine),
      columns: columns,
      rows: if(truncated, do: Enum.take(rows, limit), else: rows),
      truncated: truncated
    }
  end

  defp engine_name(:postgres), do: "postgres"
  defp engine_name(:sqlite), do: "sqlite"

  defp maybe_limit(sql, keyword, limit) when keyword in ["SELECT", "WITH", "VALUES", "TABLE"] do
    "SELECT * FROM (\n#{sql}\n) AS cleat_query LIMIT #{limit + 1}"
  end

  defp maybe_limit(sql, _keyword, _limit), do: sql

  defp remote_script({:sqlite, path}, sql) do
    """
    set -euo pipefail
    DB=$(printf '%s' '#{Base.encode64(path)}' | base64 -d)
    SQL=$(printf '%s' '#{Base.encode64(sql)}' | base64 -d)
    sqlite3 -header -csv "file:${DB}?mode=ro" "$SQL"
    """
  end

  defp remote_script({:postgres, url}, sql) do
    wrapped =
      "SET statement_timeout TO #{@statement_timeout_ms}; " <>
        "SET default_transaction_read_only TO on; " <> sql

    """
    set -euo pipefail
    URL=$(printf '%s' '#{Base.encode64(url)}' | base64 -d)
    SQL=$(printf '%s' '#{Base.encode64(wrapped)}' | base64 -d)
    psql "$URL" -v ON_ERROR_STOP=1 -P pager=off --csv -c "$SQL"
    """
  end

  defp client do
    Application.get_env(:cleat_deploy, :app_query, CleatDeploy.Apps.QuerySsh)
  end

  defp strip_comments(sql) do
    sql
    |> String.replace(~r/--[^\n]*/, " ")
    |> String.replace(~r{/\*.*?\*/}s, " ")
  end

  defp extra_statement?(sql) do
    sql
    |> String.trim()
    |> String.trim_trailing(";")
    |> String.contains?(";")
  end

  defp first_keyword(sql) do
    case Regex.run(~r/\A\s*([A-Za-z]+)/, sql) do
      [_, keyword] -> String.upcase(keyword)
      _ -> nil
    end
  end

  defp write_token?(sql) do
    bare = strip_strings(sql)
    upper = String.upcase(bare)

    Enum.any?(@write_tokens, fn token ->
      Regex.match?(~r/\b#{token}\b/, upper)
    end) or Regex.match?(~r/\bINTO\b/, upper)
  end

  defp strip_strings(sql) do
    sql
    |> String.replace(~r/'(?:[^']|'')*'/, "''")
    |> String.replace(~r/"(?:[^"]|"")*"/, "\"\"")
    |> String.replace(~r/`[^`]*`/, "``")
  end

  defp postgres?(url) when is_binary(url) do
    trimmed = String.trim(url)
    String.starts_with?(trimmed, "postgres://") or String.starts_with?(trimmed, "postgresql://")
  end

  defp postgres?(_), do: false

  defp remote_libsql?(url) when is_binary(url) do
    trimmed = String.downcase(String.trim(url))
    String.starts_with?(trimmed, "libsql://") or String.starts_with?(trimmed, "https://")
  end

  defp remote_libsql?(_), do: false

  defp sqlite_path(env) when is_map(env) do
    cond do
      path = present_path(env["DATABASE_PATH"]) -> path
      path = file_sqlite_path(env["DATABASE_URL"]) -> path
      path = file_sqlite_path(env["TURSO_DATABASE_URL"]) -> path
      true -> nil
    end
  end

  defp present_path(path) when is_binary(path) do
    path = String.trim(path)
    if path == "", do: nil, else: path
  end

  defp present_path(_), do: nil

  defp file_sqlite_path(url) when is_binary(url) do
    trimmed = String.trim(url)

    cond do
      String.starts_with?(trimmed, "file://") ->
        present_path(String.replace_prefix(trimmed, "file://", ""))

      String.starts_with?(trimmed, "file:") ->
        present_path(String.replace_prefix(trimmed, "file:", ""))

      true ->
        nil
    end
  end

  defp file_sqlite_path(_), do: nil

  defp safe_sqlite_path?(path) when is_binary(path) do
    String.starts_with?(path, "/") and
      not String.contains?(path, "..") and
      not String.contains?(path, "\n") and
      not String.contains?(path, "\0")
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)
  defp clamp_limit(_), do: @default_limit

  defp parse_csv(output) when is_binary(output) do
    case output |> String.trim() |> String.split("\n", trim: true) do
      [] ->
        %{columns: [], rows: []}

      [header | rest] ->
        %{columns: parse_csv_line(header), rows: Enum.map(rest, &parse_csv_line/1)}
    end
  end

  defp parse_csv(_), do: %{columns: [], rows: []}

  defp parse_csv_line(line) do
    line
    |> String.graphemes()
    |> Enum.reduce({:field, "", [], false}, &csv_char/2)
    |> finish_csv()
  end

  defp csv_char("\"", {:field, field, acc, false}), do: {:field, field, acc, true}
  defp csv_char("\"", {:field, field, acc, true}), do: {:quote, field, acc}
  defp csv_char("\"", {:quote, field, acc}), do: {:field, field <> "\"", acc, true}
  defp csv_char(",", {:quote, field, acc}), do: {:field, "", acc ++ [field], false}
  defp csv_char(",", {:field, field, acc, false}), do: {:field, "", acc ++ [field], false}
  defp csv_char(ch, {:quote, field, acc}), do: {:field, field <> ch, acc, false}
  defp csv_char(ch, {:field, field, acc, quoted}), do: {:field, field <> ch, acc, quoted}

  defp finish_csv({:quote, field, acc}), do: acc ++ [field]
  defp finish_csv({:field, field, acc, _quoted}), do: acc ++ [field]

  defp format_error(reason) when is_binary(reason) do
    trimmed = reason |> Redact.message() |> String.trim()

    cond do
      trimmed == "" -> "Could not run the query on the VM"
      String.length(trimmed) > 400 -> String.slice(trimmed, 0, 400) <> "…"
      true -> trimmed
    end
  end

  defp format_error(reason), do: "Could not run the query on the VM (#{inspect(reason)})"
end
