defmodule CleatDeployWeb.ServerLive.Index.Helpers do
  @moduledoc false
  use CleatDeployWeb, :verified_routes

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3, push_navigate: 2, stream_insert: 3]

  alias CleatDeploy.Servers

  def create_in_cloud(socket, server_params) do
    case Servers.provision_server(socket.assigns.current_scope, server_params) do
      {:ok, server} ->
        {:noreply,
         socket
         |> stream_insert(:servers, server)
         |> assign(:server_count, socket.assigns.server_count + 1)
         |> put_flash(:info, "#{server.name} is running at #{server.host_ip}")
         |> push_navigate(to: ~p"/servers")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :server))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Servers.format_cloud_error(reason))}
    end
  end

  def register_existing(socket, server_params) do
    server_params = apply_provider_defaults(server_params)

    case Servers.create_server(socket.assigns.current_scope, server_params) do
      {:ok, server} ->
        {:noreply,
         socket
         |> stream_insert(:servers, server)
         |> assign(:server_count, socket.assigns.server_count + 1)
         |> put_flash(:info, "Server registered")
         |> push_navigate(to: ~p"/servers")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :server))}
    end
  end

  def apply_provider_defaults(%{"provider" => "hetzner"} = params) do
    params
    |> put_if_blank_or("region", "fsn1", ["", "us-east-1"])
    |> put_if_blank_or("ssh_user", "ubuntu", ["", nil])
  end

  def apply_provider_defaults(params), do: params

  def put_if_blank_or(params, key, value, replace) do
    current = Map.get(params, key)

    if current in replace do
      Map.put(params, key, value)
    else
      params
    end
  end

  def inventory_flash(result) do
    running = Enum.count(result.updated, &(&1.instance_status == "running"))
    missing = length(result.missing)
    discovered = length(result.discovered)
    private = length(result.private)

    "Cloud check: #{running} running, #{missing} missing, #{private} private, #{discovered} new"
  end

  def maybe_flash_errors(socket, []), do: socket

  def maybe_flash_errors(socket, errors) do
    names = errors |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")
    put_flash(socket, :error, "Could not check: #{names}")
  end
end
