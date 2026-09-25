defmodule CleatDeployWeb.AppLive.Index.Directory do
  @moduledoc false
  use CleatDeployWeb, :html

  alias CleatDeploy.Apps.App
  alias CleatDeployWeb.AppLive.Index.{Filters, Listing}

  def table(assigns) do
    ~H"""
    <div class="overflow-hidden rounded-md border border-hd-border bg-hd-card">
      <div class="flex items-center justify-between border-b border-hd-border bg-hd-aside px-4 py-2.5">
        <div class="space-y-0.5">
          <h3 class="font-display text-xs font-semibold text-hd-text">
            Registered Phoenix Applications
          </h3>
          <p class="text-[11px] text-hd-muted">
            Live directory mapping GitHub repositories to systemd processes
          </p>
        </div>
        <.link
          :if={@servers != []}
          navigate={~p"/apps/new"}
          class="flex items-center gap-1 font-mono text-xs font-bold text-hd-orange hover:text-hd-orange-dark"
        >
          <.icon name="hero-plus" class="size-3.5" /> Register App
        </.link>
      </div>

      <Filters.bar {assigns} />

      <div class="overflow-x-auto">
        <table id="apps-table" class="paas-table w-full text-left">
          <thead>
            <tr>
              <.sort_header field={:name} label="Name" sort={@apps_sort} dir={@apps_sort_dir} />
              <.sort_header field={:host} label="Host" sort={@apps_sort} dir={@apps_sort_dir} />
              <.sort_header
                field={:language}
                label="Main language"
                sort={@apps_sort}
                dir={@apps_sort_dir}
              />
              <.sort_header field={:ram} label="RAM" sort={@apps_sort} dir={@apps_sort_dir} />
              <.sort_header field={:cpu} label="CPU" sort={@apps_sort} dir={@apps_sort_dir} />
              <.sort_header field={:disk} label="Disk" sort={@apps_sort} dir={@apps_sort_dir} />
              <.sort_header field={:idle} label="Idle" sort={@apps_sort} dir={@apps_sort_dir} />
              <.sort_header
                field={:state}
                label="Status"
                sort={@apps_sort}
                dir={@apps_sort_dir}
              />
              <.sort_header
                field={:server}
                label="Server"
                sort={@apps_sort}
                dir={@apps_sort_dir}
              />
              <th class="text-right">Action</th>
            </tr>
          </thead>
          <tbody id="apps-list" phx-update="stream">
            <tr :if={@apps_list == [] and not @apps_filtered?} id="apps-empty">
              <td colspan="10" class="py-8 text-center text-hd-muted">
                <div class="space-y-3">
                  <p class="font-mono text-xs">No applications configured.</p>
                  <.link
                    :if={@servers != []}
                    navigate={~p"/apps/new"}
                    class="paas-btn-primary inline-flex"
                  >
                    Register App
                  </.link>
                </div>
              </td>
            </tr>
            <tr
              :if={@apps_list == [] and @apps_filtered?}
              id="apps-filter-empty"
            >
              <td colspan="10" class="py-8 text-center text-hd-muted">
                <p class="font-mono text-xs">No applications match this filter.</p>
              </td>
            </tr>
            <tr :for={{id, app} <- @streams.apps} id={id}>
              <td>
                <.link
                  navigate={~p"/apps/#{app.id}/deployments"}
                  class="font-medium text-hd-orange hover:text-hd-orange-dark"
                >
                  {app.name}
                </.link>
              </td>
              <td>
                <.link
                  href={"https://#{app.host}"}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="font-mono text-sm text-hd-orange hover:text-hd-orange-dark hover:underline"
                >
                  {app.host}
                </.link>
              </td>
              <td>
                <.language_badge app={app} />
              </td>
              <td>
                <.ram_cell app={app} memory={@app_memory[app.id]} />
              </td>
              <td>
                <.cpu_cell app={app} memory={@app_memory[app.id]} />
              </td>
              <td>
                <.disk_cell app={app} memory={@app_memory[app.id]} />
              </td>
              <td>
                <.idle_badge app={app} />
              </td>
              <td>
                <.status_cell app={app} memory={@app_memory[app.id]} />
              </td>
              <td>{app.server.name}</td>
              <td class="text-right">
                <div class="flex items-center justify-end gap-2">
                  <.link
                    :if={app.runtime != "static"}
                    id={"app-#{app.id}-deploy"}
                    navigate={~p"/apps/#{app.id}/deployments"}
                    class="paas-btn-secondary text-[10px]"
                  >
                    <.icon name="hero-rocket-launch" class="size-3" /> Deploy
                  </.link>
                  <.power_button
                    :if={app.runtime != "static"}
                    app={app}
                    memory={@app_memory[app.id]}
                  />
                  <button
                    type="button"
                    id={"app-#{app.id}-delete"}
                    phx-click="delete_app_prompt"
                    phx-value-id={app.id}
                    title="Delete app"
                    class="paas-btn-secondary px-2 py-1 text-rose-400 hover:border-rose-400/40"
                  >
                    <.icon name="hero-trash" class="size-3.5" />
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div
        :if={@apps_total_pages > 1}
        id="apps-pagination"
        class="flex flex-wrap items-center justify-between gap-3 border-t border-hd-border bg-hd-aside/40 px-4 py-2"
      >
        <span
          id="apps-page-status"
          class="font-mono text-[11px] tabular-nums text-hd-muted"
        >
          {Listing.apps_range(@apps_page, @apps_visible_count)} of {@apps_visible_count}
        </span>
        <div class="flex items-center gap-2">
          <button
            id="apps-page-first"
            type="button"
            phx-click="paginate_apps"
            phx-value-page={1}
            disabled={@apps_page <= 1}
            title="First page"
            class="paas-btn-secondary px-2 py-1 text-[10px] uppercase disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-40"
          >
            <.icon name="hero-chevron-double-left" class="size-3.5" />
          </button>
          <button
            id="apps-page-prev"
            type="button"
            phx-click="paginate_apps"
            phx-value-page={@apps_page - 1}
            disabled={@apps_page <= 1}
            class="paas-btn-secondary px-2 py-1 text-[10px] uppercase disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-40"
          >
            <.icon name="hero-chevron-left" class="size-3.5" /> Prev
          </button>
          <span class="font-mono text-[10px] uppercase tracking-widest text-hd-muted">
            Page {@apps_page}/{@apps_total_pages}
          </span>
          <button
            id="apps-page-next"
            type="button"
            phx-click="paginate_apps"
            phx-value-page={@apps_page + 1}
            disabled={@apps_page >= @apps_total_pages}
            class="paas-btn-secondary px-2 py-1 text-[10px] uppercase disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-40"
          >
            Next <.icon name="hero-chevron-right" class="size-3.5" />
          </button>
          <button
            id="apps-page-last"
            type="button"
            phx-click="paginate_apps"
            phx-value-page={@apps_total_pages}
            disabled={@apps_page >= @apps_total_pages}
            title="Last page"
            class="paas-btn-secondary px-2 py-1 text-[10px] uppercase disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-40"
          >
            <.icon name="hero-chevron-double-right" class="size-3.5" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :app, App, required: true
  attr :memory, :any, default: nil

  # Hibernate / wake button for one row of the apps list. The state comes from
  # the same systemd probe as the status column; while it is unknown the row
  # offers Hibernate, which is a no-op on an app that is already stopped.
  def power_button(assigns) do
    assigns = assign(assigns, :hibernated?, match?(%{active?: false}, assigns.memory))

    ~H"""
    <button
      id={"app-#{@app.id}-#{if @hibernated?, do: "wake", else: "hibernate"}"}
      type="button"
      phx-click={if @hibernated?, do: "wake_app", else: "hibernate_prompt"}
      phx-value-id={@app.id}
      title={
        if @hibernated?,
          do: "Wake up — starts the unit again",
          else: "Hibernate — stops the process (no CPU/RAM), release stays on disk"
      }
      class={["paas-btn-secondary px-2 py-1", @hibernated? && "text-hd-blue"]}
    >
      <.icon name={if @hibernated?, do: "hero-bolt", else: "hero-moon"} class="size-3.5" />
    </button>
    """
  end

  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :sort, :atom, required: true
  attr :dir, :atom, required: true

  def sort_header(assigns) do
    active? = assigns.sort == assigns.field
    assigns = assign(assigns, :active?, active?)

    ~H"""
    <th>
      <button
        id={"sort-apps-#{@field}"}
        type="button"
        phx-click="sort_apps"
        phx-value-by={@field}
        class={[
          "inline-flex items-center gap-1 uppercase transition-colors",
          @active? && "text-hd-text",
          not @active? && "text-hd-muted hover:text-hd-text"
        ]}
      >
        {@label}
        <.icon
          :if={@active?}
          name={if @dir == :asc, do: "hero-chevron-up", else: "hero-chevron-down"}
          class="size-3"
        />
      </button>
    </th>
    """
  end
end
