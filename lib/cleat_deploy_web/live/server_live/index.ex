defmodule CleatDeployWeb.ServerLive.Index do
  use CleatDeployWeb, :live_view

  alias CleatDeploy.Apps
  alias CleatDeploy.Servers
  alias CleatDeploy.Servers.Server
  alias CleatDeployWeb.ServerLive.Index.{Directory, Form, Helpers}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:page_title, "Servers")
     |> assign(:active_tab, :servers)
     |> assign(:syncing?, false)
     |> assign(:discovered, [])
     |> assign(:confirming_server, nil)
     |> assign(:form_mode, :create)
     |> assign(:plan_currency, :eur)
     |> assign(:app_counts, Apps.count_apps_by_server_id(scope))
     |> stream(:servers, Servers.list_servers(scope))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New server")
    |> assign(:server, %Server{})
    |> assign(:form_mode, :create)
    |> assign(:form, to_form(Servers.change_provision(), as: :server))
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Servers")
    |> assign(:server, nil)
    |> assign(:form_mode, :create)
    |> assign(:form, nil)
  end

  @impl true
  def handle_event("set_plan_currency", %{"currency" => currency}, socket) do
    currency = if currency == "usd", do: :usd, else: :eur
    {:noreply, assign(socket, :plan_currency, currency)}
  end

  def handle_event("set_form_mode", %{"mode" => mode}, socket) do
    mode = if mode == "register", do: :register, else: :create

    form =
      if mode == :register do
        to_form(Servers.change_server(%Server{}, %{"provider" => "hetzner", "region" => "fsn1"}))
      else
        to_form(Servers.change_provision(), as: :server)
      end

    {:noreply, socket |> assign(:form_mode, mode) |> assign(:form, form)}
  end

  def handle_event("validate", %{"server" => server_params}, socket) do
    changeset =
      case socket.assigns.form_mode do
        :create ->
          server_params
          |> Servers.change_provision()
          |> Map.put(:action, :validate)

        _ ->
          %Server{}
          |> Servers.change_server(Helpers.apply_provider_defaults(server_params))
          |> Map.put(:action, :validate)
      end

    {:noreply, assign(socket, form: to_form(changeset, as: :server))}
  end

  def handle_event("save", %{"server" => server_params}, socket) do
    if socket.assigns.form_mode == :create do
      Helpers.create_in_cloud(socket, server_params)
    else
      Helpers.register_existing(socket, server_params)
    end
  end

  def handle_event("sync_cloud", _params, socket) do
    scope = socket.assigns.current_scope
    {result, servers} = Servers.sync_inventory(scope)

    {:noreply,
     socket
     |> assign(:syncing?, false)
     |> assign(:discovered, result.discovered)
     |> assign(:app_counts, Apps.count_apps_by_server_id(scope))
     |> assign(:server_count, length(servers))
     |> stream(:servers, servers, reset: true)
     |> put_flash(:info, Helpers.inventory_flash(result))
     |> Helpers.maybe_flash_errors(result.errors)}
  end

  def handle_event("confirm_remove", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    server = Servers.get_server!(scope, String.to_integer(id))
    {:noreply, assign(socket, :confirming_server, server)}
  end

  def handle_event("cancel_remove", _params, socket) do
    {:noreply, assign(socket, :confirming_server, nil)}
  end

  def handle_event("remove_server", _params, socket) do
    scope = socket.assigns.current_scope

    case socket.assigns.confirming_server do
      nil ->
        {:noreply, socket}

      server ->
        case Servers.delete_server(scope, server) do
          {:ok, deleted} ->
            servers = Servers.list_servers(scope)

            {:noreply,
             socket
             |> stream_delete(:servers, deleted)
             |> assign(:confirming_server, nil)
             |> assign(:server_count, length(servers))
             |> assign(:app_counts, Apps.count_apps_by_server_id(scope))
             |> put_flash(:info, "#{deleted.name} removed from the panel")}

          {:error, :has_apps} ->
            {:noreply,
             socket
             |> assign(:confirming_server, nil)
             |> put_flash(:error, "Move or delete this server's apps before removing it")}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(:confirming_server, nil)
             |> put_flash(:error, "Could not remove server")}
        end
    end
  end

  def handle_event("register_discovered", params, socket) do
    scope = socket.assigns.current_scope
    host_ip = params["host_ip"]

    if host_ip in [nil, ""] do
      {:noreply, put_flash(socket, :error, "That cloud VM has no public IPv4 yet")}
    else
      attrs = %{
        "name" => params["name"],
        "host_ip" => host_ip,
        "provider" => params["provider"],
        "region" => params["region"] || "us-east-1",
        "aws_instance_name" => params["name"],
        "ssh_user" => "ubuntu"
      }

      case Servers.create_server(scope, attrs) do
        {:ok, server} ->
          discovered =
            Enum.reject(socket.assigns.discovered, fn remote ->
              remote.name == server.name and remote.provider == server.provider
            end)

          {:noreply,
           socket
           |> stream_insert(:servers, server)
           |> assign(:discovered, discovered)
           |> assign(:server_count, socket.assigns.server_count + 1)
           |> put_flash(:info, "#{server.name} registered")}

        {:error, %Ecto.Changeset{}} ->
          {:noreply, put_flash(socket, :error, "Could not register #{params["name"]}")}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_tab={@active_tab}
      server_count={@server_count}
      app_count={@app_count}
    >
      <div class="space-y-4">
        <div class="flex items-center justify-between gap-4">
          <div>
            <h2 class="font-display text-sm font-semibold text-hd-text">Deploy servers</h2>
            <p class="text-[11px] text-hd-muted">
              Hetzner Cloud and AWS Lightsail VMs hosting Phoenix and Go applications
            </p>
          </div>
          <div :if={@live_action == :index} class="flex items-center gap-2">
            <button
              id="sync-cloud-button"
              type="button"
              phx-click="sync_cloud"
              phx-disable-with="Checking…"
              class="paas-btn-secondary"
            >
              <.icon name="hero-arrow-path" class="size-3.5" /> Check cloud
            </button>
            <.link navigate={~p"/servers/new"} class="paas-btn-primary">
              <.icon name="hero-plus" class="size-3.5" /> New server
            </.link>
          </div>
        </div>

        <Form.register_form :if={@live_action == :new} {assigns} />
        <Directory.grid {assigns} />
      </div>
    </Layouts.app>
    """
  end
end
