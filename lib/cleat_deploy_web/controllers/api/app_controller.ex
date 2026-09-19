defmodule CleatDeployWeb.Api.AppController do
  @moduledoc false

  use CleatDeployWeb, :controller

  alias CleatDeploy.Apps
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

  def logs(conn, %{"app_id" => app_id}) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- resolve_app(scope, app_id) do
      if app.runtime == "static" do
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "runtime_logs_unavailable"})
      else
        fetch_logs(conn, app)
      end
    else
      :error -> not_found(conn)
    end
  end

  defp fetch_logs(conn, app) do
    case Apps.RuntimeLogs.fetch(app) do
      {:ok, result} ->
        json(conn, %{
          data: %{
            unit: result.unit,
            lines: result.lines,
            fetched_at: result.fetched_at
          }
        })

      {:error, message} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "runtime_logs_failed", message: message})
    end
  end

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
end
