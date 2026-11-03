defmodule CleatDeployWeb.ServerLive.Show do
  use CleatDeployWeb, :live_view

  alias CleatDeploy.Servers
  alias CleatDeploy.Servers.Server

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    server = Servers.get_server!(scope, id)

    socket =
      socket
      |> assign(:page_title, server.name)
      |> assign(:active_tab, :servers)
      |> assign(:server, server)
      |> assign(:resize_options, Servers.list_resize_options(scope, server))
      |> assign(:selected_bundle_id, "")
      |> assign(:resizing?, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("sync_specs", _params, socket) do
    scope = socket.assigns.current_scope

    case Servers.sync_specs(scope, socket.assigns.server) do
      {:ok, %CleatDeploy.Servers.Server{instance_status: "missing"} = server} ->
        {:noreply,
         socket
         |> assign(:server, server)
         |> assign(:resize_options, [])
         |> put_flash(:error, "This instance is gone from the cloud provider")}

      {:ok, server} ->
        {:noreply,
         socket
         |> assign(:server, server)
         |> assign(:resize_options, Servers.list_resize_options(scope, server))
         |> put_flash(:info, "Machine specs refreshed")}

      {:error, :missing_instance_name} ->
        {:noreply, put_flash(socket, :error, "Set the instance name to sync specs")}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not fetch instance specs from the cloud provider")}
    end
  end

  def handle_event("select_bundle", %{"bundle_id" => bundle_id}, socket) do
    {:noreply, assign(socket, :selected_bundle_id, bundle_id)}
  end

  def handle_event("resize_bundle", _params, socket) do
    scope = socket.assigns.current_scope
    bundle_id = socket.assigns.selected_bundle_id

    if bundle_id in ["", nil] do
      {:noreply, put_flash(socket, :error, "Select a plan to upgrade or downgrade")}
    else
      socket = assign(socket, :resizing?, true)

      case Servers.resize_bundle(scope, socket.assigns.server, bundle_id) do
        {:ok, server} ->
          {:noreply,
           socket
           |> assign(:server, server)
           |> assign(:resize_options, Servers.list_resize_options(scope, server))
           |> assign(:selected_bundle_id, "")
           |> assign(:resizing?, false)
           |> put_flash(:info, "Instance plan updated")}

        {:error, :missing_instance_name} ->
          {:noreply,
           socket
           |> assign(:resizing?, false)
           |> put_flash(:error, "Set the instance name before resizing")}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(:resizing?, false)
           |> put_flash(:error, "Could not change instance plan")}
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
      <div class="space-y-5">
        <div class="flex flex-wrap items-end justify-between gap-3">
          <div class="space-y-1">
            <.link
              navigate={~p"/servers"}
              class="text-xs text-hd-muted transition-colors hover:text-hd-text"
            >
              ← Back to servers
            </.link>
            <h2 class="text-xl font-medium tracking-tight text-hd-text">{@server.name}</h2>
            <p class="font-mono text-xs text-hd-muted">
              {@server.region} · {@server.host_ip}
              <span :if={@server.aws_instance_name}>
                · {@server.aws_instance_name}
              </span>
            </p>
          </div>
          <button
            id="sync-specs-button"
            type="button"
            phx-click="sync_specs"
            class="paas-btn-secondary"
          >
            <.icon name="hero-arrow-path" class="size-3.5" /> Refresh specs
          </button>
        </div>

        <div class="paas-card p-5">
          <div id="server-specs" class="grid gap-x-6 gap-y-5 sm:grid-cols-2 lg:grid-cols-4">
            <.info_tile
              label="Plan"
              value={@server.bundle_name || "Unknown"}
              mono
              sub={@server.bundle_id || "Not synced"}
            />
            <.info_tile
              label="vCPU"
              value={if(@server.cpu_count, do: "#{@server.cpu_count} cores", else: "—")}
            />
            <.info_tile
              label="Memory"
              value={Server.format_ram(@server)}
            />
            <.info_tile
              label="Disk"
              value={if(@server.disk_gb, do: "#{@server.disk_gb} GB", else: "—")}
            />
            <.info_tile
              label="Status"
              value={@server.instance_status || "—"}
            />
            <.info_tile
              label="Cost"
              value={Server.format_price(@server)}
              sub={provider_label(@server)}
            />
            <.info_tile
              label="Synced"
              value={format_synced_at(@server.specs_synced_at)}
            />
            <.info_tile
              label="SSH key"
              value={if(Servers.ssh_key_configured?(@server), do: "Configured", else: "Missing")}
            />
            <.info_tile
              label="Mode"
              value={if(@server.deploy_mode == "dedicated", do: "Dedicated", else: "Shared")}
            />
          </div>
        </div>

        <div class="paas-card space-y-4 p-5">
          <div class="space-y-0.5">
            <h3 class="text-sm font-medium text-hd-text">
              Upgrade or downgrade plan
            </h3>
            <p class="text-xs text-hd-muted">
              Changes the instance plan for this VM. The instance may restart briefly.
            </p>
          </div>

          <form
            id="resize-bundle-form"
            phx-change="select_bundle"
            class="grid gap-3 md:grid-cols-[1fr_auto]"
          >
            <select
              id="resize-bundle-select"
              name="bundle_id"
              class="paas-select"
              disabled={@resize_options == [] or @resizing?}
            >
              <option value="">Select a new plan…</option>
              <option
                :for={bundle <- @resize_options}
                value={bundle.bundle_id}
                selected={bundle.bundle_id == @selected_bundle_id}
              >
                {bundle_label(bundle, @server)}
              </option>
            </select>
            <button
              id="resize-bundle-button"
              type="button"
              phx-click="resize_bundle"
              disabled={@selected_bundle_id == "" or @resizing?}
              class={["paas-btn-primary", @resizing? && "opacity-50"]}
            >
              <.icon
                name={if @resizing?, do: "hero-arrow-path", else: "hero-arrows-up-down"}
                class={["size-3.5", @resizing? && "motion-safe:animate-spin"]}
              />
              {if @resizing?, do: "Resizing…", else: "Apply plan change"}
            </button>
          </form>

          <p :if={@resize_options == []} class="text-[11px] text-hd-muted">
            Sync specs from the cloud provider to load available upgrade and downgrade options.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp bundle_label(bundle, server) do
    direction =
      cond do
        is_integer(server.ram_mb) and bundle.ram_mb > server.ram_mb -> "upgrade"
        is_integer(server.ram_mb) and bundle.ram_mb < server.ram_mb -> "downgrade"
        true -> "change"
      end

    price = bundle_price(bundle, server)
    ram = Server.format_ram(%Server{ram_mb: bundle.ram_mb})

    "#{bundle.bundle_name} · #{bundle.cpu_count} vCPU · #{ram} · #{bundle.disk_gb} GB · #{price} (#{direction})"
  end

  defp bundle_price(bundle, %Server{provider: "hetzner"}) do
    "€#{Decimal.round(bundle.monthly_price_usd, 2)}/mo"
  end

  defp bundle_price(bundle, _server) do
    CleatDeploy.AWS.Lightsail.Bundle.format_price(bundle)
  end

  defp provider_label(%Server{provider: "hetzner"}), do: "Hetzner Cloud"
  defp provider_label(_), do: "AWS Lightsail"

  defp format_synced_at(nil), do: "Never"

  defp format_synced_at(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end
end
