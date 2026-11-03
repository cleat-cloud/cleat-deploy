defmodule CleatDeployWeb.DashboardLive do
  use CleatDeployWeb, :live_view

  alias CleatDeploy.{Servers, Settings}
  alias CleatDeploy.Servers.{HostStats, Insights}

  @live_ms 5_000
  @hetzner_ms 60_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:active_tab, :dashboard)
      |> assign(:host_sample, nil)
      |> assign(:live_host?, false)
      |> assign(:servers, Servers.list_servers(socket.assigns.current_scope))
      # Hetzner metrics are three sequential HTTP calls. Paint first; :tick_hetzner
      # fills the 24h charts after the socket connects.
      |> load_insights(metrics: false)
      |> refresh_resources()

    socket =
      if connected?(socket) do
        send(self(), :tick_hetzner)

        socket
        |> arm_live()
        |> schedule_live()
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_info(:tick_live, socket) do
    {:noreply, socket |> apply_live() |> schedule_live()}
  end

  def handle_info(:tick_hetzner, socket) do
    {:noreply,
     socket
     |> load_insights(metrics: true)
     |> refresh_resources()
     |> apply_live()
     |> schedule_hetzner()}
  end

  @impl true
  def handle_event("select_active_server", %{"server_id" => server_id}, socket) do
    case Enum.find(socket.assigns.servers, &(to_string(&1.id) == server_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Unknown server")}

      server ->
        case Settings.put_active_server(socket.assigns.current_scope, server.id) do
          {:ok, _setting} ->
            if connected?(socket), do: send(self(), :tick_hetzner)

            {:noreply,
             socket
             |> load_insights(metrics: false)
             |> refresh_resources()
             |> arm_live()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not switch the active server")}
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
      <div id="dashboard" class="space-y-6">
        <div
          :if={@insights.server}
          id="server-overview"
          class="paas-card flex flex-wrap items-start justify-between gap-4 px-5 py-4"
        >
          <div class="min-w-0 space-y-1">
            <p class="text-xs text-hd-muted">Active server</p>
            <form
              :if={length(@servers) > 1}
              id="active-server-form"
              phx-change="select_active_server"
            >
              <select
                id="active-server-select"
                class="paas-select max-w-[18rem]"
                name="server_id"
                aria-label="Active server"
              >
                <option
                  :for={server <- @servers}
                  value={server.id}
                  selected={server.id == @insights.server.id}
                >
                  {server.name}
                </option>
              </select>
            </form>
            <h2
              :if={length(@servers) <= 1}
              id="active-server-name"
              class="text-lg font-medium tracking-tight text-hd-text"
            >
              {@insights.server.name}
            </h2>
            <p class="font-mono text-xs text-hd-muted">
              {server_spec(@insights.server)}
            </p>
          </div>
          <span
            id="active-server-status"
            class="flex shrink-0 items-center gap-1.5 pt-0.5 text-[13px]"
          >
            <span class={["size-1.5 rounded-full", status_dot(@insights.server.instance_status)]} />
            <span class={status_class(@insights.server.instance_status)}>
              {@insights.server.instance_status || "unknown"}
            </span>
          </span>
        </div>

        <div id="fleet-stats" class="paas-card grid grid-cols-2 lg:grid-cols-4">
          <.link
            navigate={~p"/servers"}
            class="border-r border-b border-hd-border/60 p-5 transition-colors hover:bg-hd-raised/30 lg:border-b-0"
          >
            <p class="text-[13px] text-hd-secondary">Servers</p>
            <div class="mt-1.5 flex items-baseline gap-2">
              <p class="font-mono text-[28px] leading-8 font-medium tabular-nums tracking-tight text-hd-text">
                {@server_count}
              </p>
              <p class="text-xs text-hd-muted">registered</p>
            </div>
          </.link>

          <.link
            id="metric-apps"
            navigate={~p"/apps"}
            class="border-b border-hd-border/60 p-5 transition-colors hover:bg-hd-raised/30 lg:border-r lg:border-b-0"
          >
            <p class="text-[13px] text-hd-secondary">Apps</p>
            <div class="mt-1.5 flex items-baseline gap-2">
              <p class="font-mono text-[28px] leading-8 font-medium tabular-nums tracking-tight text-hd-text">
                {@app_count}
              </p>
              <p class="text-xs text-hd-muted">deployed</p>
            </div>
          </.link>

          <div
            id="metric-disk"
            class="border-r border-hd-border/60 p-5"
          >
            <p class="text-[13px] text-hd-secondary">Disk used</p>
            <div class="mt-1.5 flex items-baseline gap-2">
              <p class="font-mono text-[28px] leading-8 font-medium tabular-nums tracking-tight text-hd-text">
                {usage_pct(@resources && @resources.disk)}
              </p>
              <p class="text-xs text-hd-muted">{usage_hint(@resources && @resources.disk)}</p>
            </div>
          </div>

          <div id="metric-memory" class="p-5">
            <p class="text-[13px] text-hd-secondary">Memory used</p>
            <div class="mt-1.5 flex items-baseline gap-2">
              <p class="font-mono text-[28px] leading-8 font-medium tabular-nums tracking-tight text-hd-text">
                {usage_pct(@resources && @resources.memory)}
              </p>
              <p class="text-xs text-hd-muted">{usage_hint(@resources && @resources.memory)}</p>
            </div>
          </div>
        </div>

        <div id="server-charts" class="space-y-3">
          <div class="grid gap-3 lg:grid-cols-3">
            <div class="lg:col-span-2">
              <.area_chart
                id="chart-cpu"
                title="CPU · 24h"
                hint={cpu_hint(@live_host?)}
                live?={@live_host?}
                current={format_cpu(@insights.cpu_now)}
                series={@insights.metrics.cpu}
                height_class="h-44"
              />
            </div>
            <.dual_line_chart
              id="chart-network"
              title="Network · 24h"
              hint={net_hint(@live_host?)}
              live?={@live_host?}
              current={format_net(@insights.net_in_now, @insights.net_out_now)}
              inbound={@insights.metrics.network_in}
              outbound={@insights.metrics.network_out}
            />
          </div>
          <div class="grid gap-3 lg:grid-cols-2">
            <.runtime_bars
              id="chart-runtimes"
              elixir={@insights.runtimes.elixir}
              gleam={@insights.runtimes.gleam}
              go={@insights.runtimes.go}
              js={@insights.runtimes.node}
              ruby={@insights.runtimes.ruby}
              rust={@insights.runtimes.rust}
              static={@insights.runtimes.static}
            />
            <.deploy_bars id="chart-deploys" days={@insights.deploys} />
            <.visited_bars
              id="chart-visited"
              apps={@insights.top_visited}
              stale={@insights.visited_stale}
            />
            <.access_bars id="chart-access" apps={@insights.top_apps} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp server_spec(server) do
    parts =
      [
        server.bundle_name,
        cpu_label(server.cpu_count),
        ram_label(server.ram_mb),
        disk_label(server.disk_gb),
        server.region
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: server.host_ip || "—", else: Enum.join(parts, " · ")
  end

  defp cpu_label(n) when is_integer(n) and n > 0, do: "#{n} vCPU"
  defp cpu_label(_), do: nil

  defp ram_label(mb) when is_integer(mb) and mb >= 1024, do: "#{div(mb, 1024)} GB RAM"
  defp ram_label(mb) when is_integer(mb) and mb > 0, do: "#{mb} MB RAM"
  defp ram_label(_), do: nil

  defp disk_label(gb) when is_integer(gb) and gb > 0, do: "#{gb} GB disk"
  defp disk_label(_), do: nil

  defp status_class("running"), do: "text-hd-green"
  defp status_class("missing"), do: "text-hd-red"
  defp status_class(_), do: "text-hd-muted"

  defp status_dot("running"), do: "bg-hd-green"
  defp status_dot("missing"), do: "bg-hd-red"
  defp status_dot(_), do: "bg-hd-muted/50"

  defp load_insights(socket, opts) do
    assign(socket, :insights, Insights.snapshot(socket.assigns.current_scope, opts))
  end

  # Disk/memory of the host the panel runs on; nil when the primary server is
  # remote (the counters come from the local /proc and df).
  defp refresh_resources(socket) do
    assign(socket, :resources, resources_for(socket.assigns.insights.server))
  end

  defp resources_for(nil), do: nil

  defp resources_for(server) do
    if HostStats.local?(server), do: HostStats.resources(), else: nil
  end

  defp usage_pct(%{pct: pct}) when is_number(pct), do: "#{round(pct)}%"
  defp usage_pct(_), do: "—"

  defp usage_hint(%{used: used, total: total}), do: "#{gb(used)} / #{gb(total)} GB"
  defp usage_hint(_), do: "—"

  defp gb(bytes) when is_integer(bytes) do
    :erlang.float_to_binary(bytes / 1_073_741_824, decimals: 1)
  end

  defp arm_live(socket) do
    server = socket.assigns.insights.server

    if HostStats.local?(server) do
      case HostStats.sample() do
        {:ok, sample} -> assign(socket, host_sample: sample, live_host?: true)
        _ -> assign(socket, live_host?: false)
      end
    else
      assign(socket, live_host?: false)
    end
  end

  defp apply_live(%{assigns: %{live_host?: true, host_sample: prev}} = socket)
       when is_map(prev) do
    server = socket.assigns.insights.server
    cores = cores(server)

    case HostStats.sample() do
      {:ok, now} ->
        stats = HostStats.diff(prev, now, cores)

        socket
        |> assign(:host_sample, now)
        |> assign(:insights, put_live(socket.assigns.insights, stats))

      _ ->
        socket
    end
  end

  defp apply_live(socket), do: socket

  defp put_live(insights, stats) do
    %{
      insights
      | cpu_now: stats.cpu_pct,
        net_in_now: stats.net_in,
        net_out_now: stats.net_out,
        metrics: %{
          insights.metrics
          | cpu: overlay_last(insights.metrics.cpu, stats.cpu_pct),
            network_in: overlay_last(insights.metrics.network_in, stats.net_in),
            network_out: overlay_last(insights.metrics.network_out, stats.net_out)
        }
    }
  end

  defp overlay_last([_ | _] = series, value) when is_number(value) do
    List.update_at(series, -1, fn point -> %{point | v: value} end)
  end

  defp overlay_last(series, _), do: series

  defp cores(%{cpu_count: n}) when is_integer(n) and n > 0, do: n

  defp cores(_) do
    case :erlang.system_info(:logical_processors) do
      n when is_integer(n) and n > 0 -> n
      _ -> 1
    end
  end

  defp schedule_live(socket) do
    Process.send_after(self(), :tick_live, @live_ms)
    socket
  end

  defp schedule_hetzner(socket) do
    Process.send_after(self(), :tick_hetzner, @hetzner_ms)
    socket
  end

  defp cpu_hint(true), do: "Live · 100% = 1 vCPU"
  defp cpu_hint(false), do: "From the HCloud API"

  defp net_hint(true), do: "Live in / out"
  defp net_hint(false), do: "In / out bandwidth"

  defp format_cpu(nil), do: "—"

  defp format_cpu(value) when is_number(value) do
    :erlang.float_to_binary(value / 1, decimals: 1) <> "%"
  end

  defp format_net(nil, nil), do: "—"

  defp format_net(inbound, outbound) do
    "#{format_bps(inbound)} in · #{format_bps(outbound)} out"
  end

  defp format_bps(nil), do: "—"
  defp format_bps(v) when v >= 1_000_000, do: rate(v / 1_000_000, "MB/s")
  defp format_bps(v) when v >= 1_000, do: rate(v / 1_000, "KB/s")
  defp format_bps(v), do: rate(v, "B/s")

  defp rate(v, unit), do: :erlang.float_to_binary(v / 1, decimals: 1) <> " " <> unit
end
