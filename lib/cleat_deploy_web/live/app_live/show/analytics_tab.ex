defmodule CleatDeployWeb.AppLive.Show.AnalyticsTab do
  @moduledoc false
  use CleatDeployWeb, :html

  def render(assigns) do
    ~H"""
    <div :if={@app_detail_tab == :analytics} id="app-analytics" class="space-y-6">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="space-y-0.5">
          <h3 class="font-display text-xs font-semibold text-hd-text">Analytics</h3>
          <p class="text-[11px] text-hd-muted">Applies on the next deploy.</p>
        </div>
        <button
          id="analytics-inject-toggle"
          type="button"
          phx-click="toggle_analytics_inject"
          data-state={if @app.analytics_inject, do: "on", else: "off"}
          title="First-party pageviews. Takes effect on the next deploy."
          class={[
            "inline-flex items-center gap-1 rounded-md border px-2.5 py-1 font-mono text-[10px] font-semibold tracking-wide uppercase transition-colors",
            @app.analytics_inject && "border-hd-green/50 bg-hd-green/10 text-hd-green",
            !@app.analytics_inject &&
              "border-hd-border bg-hd-card text-hd-muted hover:border-hd-orange/40 hover:text-hd-text"
          ]}
        >
          <.icon name="hero-chart-bar" class="size-3" />
          analytics {if @app.analytics_inject, do: "on", else: "off"}
        </button>
      </div>

      <div class="flex flex-wrap items-center gap-1">
        <.link
          :for={range <- ~w(24h 7d 90d)}
          id={"analytics-range-#{range}"}
          patch={~p"/apps/#{@app.id}?#{[tab: "analytics", range: range]}"}
          class={[
            "rounded-md px-2 py-1 font-mono text-[10px] font-semibold uppercase tracking-wide transition-colors",
            @analytics_range == range && "border border-hd-border bg-hd-card text-hd-orange",
            @analytics_range != range && "text-hd-muted hover:text-hd-text"
          ]}
        >
          {range}
        </.link>
      </div>

      <div
        :if={!@app.analytics_inject}
        class="rounded border border-dashed border-hd-border px-4 py-6 text-center text-xs text-hd-muted"
      >
        Not measuring
      </div>

      <div :if={@app.analytics_inject && @analytics_summary} class="space-y-6">
        <div class="grid gap-3 sm:grid-cols-2">
          <div class="rounded-md border border-hd-border bg-hd-aside px-3 py-2">
            <p class="font-mono text-[10px] font-semibold uppercase tracking-wider text-hd-muted">
              Pageviews
            </p>
            <p class="mt-1 font-mono text-lg tabular-nums text-hd-text">
              {@analytics_summary.pageviews}
            </p>
          </div>
          <div class="rounded-md border border-hd-border bg-hd-aside px-3 py-2">
            <p class="font-mono text-[10px] font-semibold uppercase tracking-wider text-hd-muted">
              Uniques
            </p>
            <p class="mt-1 font-mono text-lg tabular-nums text-hd-text">
              {@analytics_summary.uniques}
            </p>
            <p class="text-[11px] text-hd-muted">hash per UTC day</p>
          </div>
        </div>

        <div class="space-y-2">
          <h4 class="font-mono text-[10px] font-semibold uppercase tracking-wider text-hd-muted">
            Paths
          </h4>
          <div class="overflow-hidden rounded border border-hd-border">
            <table id="analytics-paths" class="paas-table w-full text-left font-mono">
              <thead>
                <tr>
                  <th>Path</th>
                  <th>Pageviews</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@analytics_summary.paths == []}>
                  <td colspan="2" class="text-[11px] text-hd-muted">No paths yet</td>
                </tr>
                <tr :for={row <- @analytics_summary.paths}>
                  <td class="text-[11px] text-hd-text">{row.path}</td>
                  <td class="tabular-nums text-[11px] text-hd-muted">{row.pageviews}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="space-y-2">
          <h4 class="font-mono text-[10px] font-semibold uppercase tracking-wider text-hd-muted">
            Referrers
          </h4>
          <div class="overflow-hidden rounded border border-hd-border">
            <table id="analytics-referrers" class="paas-table w-full text-left font-mono">
              <thead>
                <tr>
                  <th>Referrer</th>
                  <th>Pageviews</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@analytics_summary.referrers == []}>
                  <td colspan="2" class="text-[11px] text-hd-muted">No referrers yet</td>
                </tr>
                <tr :for={row <- @analytics_summary.referrers}>
                  <td class="text-[11px] text-hd-text">{row.referrer}</td>
                  <td class="tabular-nums text-[11px] text-hd-muted">{row.pageviews}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="space-y-2">
          <h4 class="font-mono text-[10px] font-semibold uppercase tracking-wider text-hd-muted">
            UTM
          </h4>
          <div class="overflow-hidden rounded border border-hd-border">
            <table id="analytics-utm" class="paas-table w-full text-left font-mono">
              <thead>
                <tr>
                  <th>Source</th>
                  <th>Medium</th>
                  <th>Campaign</th>
                  <th>Pageviews</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@analytics_summary.utm == []}>
                  <td colspan="4" class="text-[11px] text-hd-muted">No UTM yet</td>
                </tr>
                <tr :for={row <- @analytics_summary.utm}>
                  <td class="text-[11px] text-hd-text">{row.source}</td>
                  <td class="text-[11px] text-hd-muted">{row.medium}</td>
                  <td class="text-[11px] text-hd-text">{row.campaign}</td>
                  <td class="tabular-nums text-[11px] text-hd-muted">{row.pageviews}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
