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

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{error: "not_found"})
  end
end
