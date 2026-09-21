defmodule CleatDeployWeb.Api.ServerController do
  @moduledoc false

  use CleatDeployWeb, :controller

  alias CleatDeploy.Logs
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

  def logs(conn, %{"id" => id} = params) do
    case fetch_server(conn.assigns.current_scope, id) do
      {:ok, server} ->
        case Logs.fetch_server(server, log_opts(params)) do
          {:ok, result} ->
            json(conn, %{
              data: %{unit: result.unit, lines: result.lines, fetched_at: result.fetched_at}
            })

          {:error, message} ->
            log_error(conn, message)
        end

      :error ->
        not_found(conn)
    end
  end

  defp log_opts(params) do
    %{unit: params["unit"], since: params["since"], tail: params["tail"], grep: params["grep"]}
  end

  defp log_error(conn, message) do
    validation? = validation_error?(message)

    conn
    |> put_status(if(validation?, do: :unprocessable_entity, else: :bad_gateway))
    |> json(%{
      error: if(validation?, do: "invalid_request", else: "runtime_logs_failed"),
      message: message
    })
  end

  defp validation_error?(message) do
    String.starts_with?(message, "invalid") or String.starts_with?(message, "tail") or
      String.starts_with?(message, "grep")
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

  def provision(conn, params) do
    case Servers.provision_server(conn.assigns.current_scope, params) do
      {:ok, server} ->
        conn
        |> put_status(:created)
        |> json(%{data: Serializer.server(server)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_request", details: errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "provision_failed", message: format_reason(reason)})
    end
  end

  def resize_options(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case fetch_server(scope, id) do
      {:ok, server} ->
        options = Servers.list_resize_options(scope, server)
        json(conn, %{data: Enum.map(options, &Serializer.bundle/1)})

      :error ->
        not_found(conn)
    end
  end

  def resize(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope

    case fetch_server(scope, id) do
      {:ok, server} -> do_resize(conn, scope, server, params["bundle_id"])
      :error -> not_found(conn)
    end
  end

  defp do_resize(conn, scope, server, bundle_id) when is_binary(bundle_id) and bundle_id != "" do
    case Servers.resize_bundle(scope, server, bundle_id) do
      {:ok, updated} -> json(conn, %{data: Serializer.server(updated)})
      {:error, reason} -> sync_error(conn, reason)
    end
  end

  defp do_resize(conn, _scope, _server, _bundle_id) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "missing_bundle_id"})
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
