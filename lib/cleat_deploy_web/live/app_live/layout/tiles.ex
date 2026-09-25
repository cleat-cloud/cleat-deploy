defmodule CleatDeployWeb.AppLive.Layout.Tiles do
  @moduledoc false
  use CleatDeployWeb, :html

  # info_tile comes from html_helpers via :html

  attr :app, :map, required: true
  attr :memory, :any, default: nil

  def shell_info_tiles(assigns) do
    peak = CleatDeploy.Apps.RuntimeMemory.format_peak(assigns.memory)

    assigns =
      assign(assigns,
        ram_label: CleatDeploy.Apps.RuntimeMemory.format(assigns.memory),
        ram_sub: peak || "systemd cgroup",
        cpu_label: CleatDeploy.Apps.RuntimeMemory.format_cpu(assigns.memory),
        disk_label: CleatDeploy.Apps.RuntimeMemory.format_disk(assigns.memory),
        status_label: CleatDeploy.Apps.RuntimeMemory.format_status(assigns.memory)
      )

    ~H"""
    <div class="space-y-3">
      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <.info_tile label="Domain Host" value={@app.host} mono sub="IPv4 ingress endpoint" />
        <.info_tile
          id="app-deploy-branch-tile"
          label="Deploy Branch"
          value={@app.branch}
          mono
          sub="Edit auto-deploy target"
          href={~p"/apps/#{@app.id}?tab=webhook"}
        />
        <.info_tile label="Target Server" value={@app.server.host_ip} mono sub={@app.server.name} />
        <.info_tile
          label="Auto Deploy"
          value={if @app.auto_deploy, do: "Webhook Enabled", else: "Manual Selector"}
          sub="HMAC Sha256 keys"
        />
      </div>
      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <.info_tile id="app-memory-tile" label="Memory" value={@ram_label} mono sub={@ram_sub} />
        <.info_tile id="app-cpu-tile" label="CPU" value={@cpu_label} mono sub="Share of one vCPU" />
        <.info_tile id="app-disk-tile" label="Disk" value={@disk_label} mono sub="Release + data" />
        <.info_tile
          id="app-status-tile"
          label="Status"
          value={@status_label}
          mono
          sub="systemd unit"
        />
      </div>
    </div>
    """
  end
end
