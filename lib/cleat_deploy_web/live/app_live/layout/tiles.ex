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
    <div class="paas-card p-5">
      <div class="grid gap-x-6 gap-y-5 sm:grid-cols-2 lg:grid-cols-4">
        <.info_tile label="Domain" value={@app.host} mono />
        <.info_tile
          id="app-deploy-branch-tile"
          label="Branch"
          value={@app.branch}
          mono
          sub="Edit in Webhook"
          href={~p"/apps/#{@app.id}?tab=webhook"}
        />
        <.info_tile label="Server" value={@app.server.host_ip} mono sub={@app.server.name} />
        <.info_tile
          label="Auto deploy"
          value={if @app.auto_deploy, do: "Webhook", else: "Manual"}
          sub={if @app.auto_deploy, do: "GitHub push triggers a deploy"}
        />
        <.info_tile id="app-memory-tile" label="Memory" value={@ram_label} mono sub={@ram_sub} />
        <.info_tile id="app-cpu-tile" label="CPU" value={@cpu_label} mono />
        <.info_tile id="app-disk-tile" label="Disk" value={@disk_label} mono />
        <.info_tile
          id="app-status-tile"
          label="Unit"
          value={@status_label}
          mono
        />
      </div>
    </div>
    """
  end
end
