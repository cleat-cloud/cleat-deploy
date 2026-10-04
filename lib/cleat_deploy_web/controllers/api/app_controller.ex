defmodule CleatDeployWeb.Api.AppController do
  @moduledoc false

  use CleatDeployWeb, :controller

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.Query
  alias CleatDeploy.Logs
  alias CleatDeployWeb.Api.LogError
  alias CleatDeployWeb.Api.Serializer

  def index(conn, params) do
    scope = conn.assigns.current_scope

    apps =
      scope
      |> Apps.list_apps()
      |> filter_by_slug(params["slug"])

    json(conn, %{data: Enum.map(apps, &Serializer.app/1)})
  end

  def show(conn, %{"id" => id}) do
    case resolve_app(conn.assigns.current_scope, id) do
      {:ok, app} -> json(conn, %{data: Serializer.app(app)})
      :error -> not_found(conn)
    end
  end

  def create(conn, params) do
    scope = conn.assigns.current_scope

    case Apps.create_app(scope, params) do
      {:ok, app, _webhook_status} ->
        app = Apps.get_app!(scope, app.id)

        conn
        |> put_status(:created)
        |> json(%{data: Serializer.app(app)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_request", details: errors(changeset)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- resolve_app(scope, id) do
      case Apps.update_app_settings(scope, app, params) do
        {:ok, updated} ->
          json(conn, %{data: Serializer.app(Apps.get_app!(scope, updated.id))})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "invalid_request", details: errors(changeset)})

        {:error, :unauthorized} ->
          not_found(conn)
      end
    else
      :error -> not_found(conn)
    end
  end

  def logs(conn, %{"app_id" => app_id} = params) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- resolve_app(scope, app_id) do
      if app.runtime == "static" do
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "runtime_logs_unavailable"})
      else
        fetch_logs(conn, app, params)
      end
    else
      :error -> not_found(conn)
    end
  end

  defp fetch_logs(conn, app, params) do
    case Logs.fetch_app(app, log_opts(params)) do
      {:ok, result} ->
        json(conn, %{
          data: %{
            unit: result.unit,
            lines: result.lines,
            fetched_at: result.fetched_at
          }
        })

      {:error, reason} ->
        LogError.render(conn, reason)
    end
  end

  defp log_opts(params) do
    %{since: params["since"], tail: params["tail"], grep: params["grep"]}
  end

  def query(conn, %{"app_id" => app_id} = params) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- resolve_app(scope, app_id),
         {:ok, sql} <- sql_param(params) do
      respond_query(conn, Query.run(scope, app, sql, limit: limit_param(params)))
    else
      :error -> not_found(conn)
      {:error, :invalid_sql, message} -> unprocessable(conn, "invalid_sql", message)
    end
  end

  defp respond_query(conn, {:ok, result}) do
    json(conn, %{data: Serializer.app_query(result)})
  end

  defp respond_query(conn, {:error, :not_found}), do: not_found(conn)

  defp respond_query(conn, {:error, :invalid_sql, message}) do
    unprocessable(conn, "invalid_sql", message)
  end

  defp respond_query(conn, {:error, :no_database}) do
    unprocessable(conn, "no_database", "app has no local Postgres or SQLite")
  end

  defp respond_query(conn, {:error, :unsupported_database}) do
    unprocessable(
      conn,
      "unsupported_database",
      "remote Turso/libSQL is not queryable from the panel"
    )
  end

  defp respond_query(conn, {:error, :unsafe_path}) do
    unprocessable(conn, "unsafe_path", "DATABASE_PATH must be an absolute path")
  end

  defp respond_query(conn, {:error, :query_failed, message}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{error: "query_failed", message: message})
  end

  defp sql_param(%{"sql" => sql}) when is_binary(sql) and sql != "", do: {:ok, sql}
  defp sql_param(_), do: {:error, :invalid_sql, "provide sql"}

  defp limit_param(%{"limit" => limit}) when is_integer(limit), do: limit

  defp limit_param(%{"limit" => limit}) when is_binary(limit) do
    case Integer.parse(limit) do
      {int, ""} -> int
      _ -> 50
    end
  end

  defp limit_param(_), do: 50

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- resolve_app(scope, id) do
      case Apps.delete_app(scope, app) do
        {:ok, _app} ->
          send_resp(conn, :no_content, "")

        {:error, :unauthorized} ->
          not_found(conn)

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "invalid_request", details: errors(changeset)})
      end
    else
      :error -> not_found(conn)
    end
  end

  defp filter_by_slug(apps, nil), do: apps
  defp filter_by_slug(apps, slug), do: Enum.filter(apps, &(&1.slug == slug))

  defp resolve_app(scope, id) do
    case Integer.parse(id) do
      {int, ""} -> fetch(fn -> Apps.get_app!(scope, int) end)
      _ -> fetch(fn -> Apps.get_app_by_slug!(scope, id) end)
    end
  end

  defp fetch(fun) do
    {:ok, fun.()}
  rescue
    Ecto.NoResultsError -> :error
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{error: "not_found"})
  end

  defp unprocessable(conn, error, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: error, message: message})
  end
end
