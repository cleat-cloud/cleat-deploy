defmodule CleatDeployWeb.Api.ServerController do
  @moduledoc false

  use CleatDeployWeb, :controller

  alias CleatDeploy.Servers
  alias CleatDeployWeb.Api.Serializer

  def index(conn, _params) do
    servers = Servers.list_servers(conn.assigns.current_scope)

    json(conn, %{data: Enum.map(servers, &Serializer.server/1)})
  end

  def show(conn, %{"id" => id}) do
    case fetch_server(conn.assigns.current_scope, id) do
      {:ok, server} -> json(conn, %{data: Serializer.server(server)})
      :error -> not_found(conn)
    end
  end

  def create(conn, params) do
    case Servers.create_server(conn.assigns.current_scope, params) do
      {:ok, server} ->
        conn
        |> put_status(:created)
        |> json(%{data: Serializer.server(server)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_request", details: errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case fetch_server(scope, id) do
      {:ok, server} -> delete_server(conn, scope, server)
      :error -> not_found(conn)
    end
  end

  def sync(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case fetch_server(scope, id) do
      {:ok, server} ->
        case Servers.sync_specs(scope, server) do
          {:ok, updated} -> json(conn, %{data: Serializer.server(updated)})
          {:error, reason} -> sync_error(conn, reason)
        end

      :error ->
        not_found(conn)
    end
  end

  def start(conn, %{"id" => id}), do: power(conn, id, :start)
  def stop(conn, %{"id" => id}), do: power(conn, id, :stop)

  defp power(conn, id, action) do
    scope = conn.assigns.current_scope

    case fetch_server(scope, id) do
      {:ok, server} ->
        case Servers.power(scope, server, action) do
          {:ok, updated} -> json(conn, %{data: Serializer.server(updated)})
          {:error, reason} -> sync_error(conn, reason)
        end

      :error ->
        not_found(conn)
    end
  end

  defp delete_server(conn, scope, server) do
    case Servers.delete_server(scope, server) do
      {:ok, _server} ->
        send_resp(conn, :no_content, "")

      {:error, :has_apps} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "server_has_apps"})

      {:error, :unauthorized} ->
        not_found(conn)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_request", details: errors(changeset)})
    end
  end

  defp sync_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "sync_failed", message: format_reason(reason)})
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp fetch_server(scope, id) do
    case Integer.parse(id) do
      {int, ""} -> fetch(fn -> Servers.get_server!(scope, int) end)
      _ -> :error
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
