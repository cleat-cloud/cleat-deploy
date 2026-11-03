defmodule CleatDeployWeb.PaasComponents.Bars do
  @moduledoc false
  use Phoenix.Component

  import CleatDeployWeb.PaasComponents.Charts, only: [chart_hover_layer: 1]
  use CleatDeployWeb, :verified_routes

  attr :id, :string, required: true
  attr :elixir, :integer, required: true
  attr :gleam, :integer, default: 0
  attr :go, :integer, required: true
  attr :js, :integer, required: true
  attr :ruby, :integer, required: true
  attr :rust, :integer, default: 0
  attr :static, :integer, default: 0

  # One ranked list with a single ember leader: seven colored bars would be a
  # legend of hues for a chart that only has to rank seven counts.
  def runtime_bars(assigns) do
    counts = [
      {"Elixir", :phoenix, assigns.elixir},
      {"Gleam", :gleam, assigns.gleam},
      {"Go", :golang, assigns.go},
      {"JavaScript", :node, assigns.js},
      {"Ruby", :rails, assigns.ruby},
      {"Rust", :rust, assigns.rust},
      {"Static", :static, assigns.static}
    ]

    total = counts |> Enum.map(&elem(&1, 2)) |> Enum.sum()
    peak = counts |> Enum.map(&elem(&1, 2)) |> Enum.max(fn -> 0 end)

    rows =
      counts
      |> Enum.reject(fn {_label, _runtime, count} -> count == 0 end)
      |> Enum.map(fn {label, runtime, count} ->
        %{
          label: label,
          runtime: runtime,
          count: count,
          pct: if(total > 0, do: round(count / total * 100), else: 0),
          width: if(peak > 0, do: max(round(count / peak * 100), 3), else: 0),
          lead?: count == peak
        }
      end)

    assigns = assign(assigns, rows: rows, total: total)

    ~H"""
    <section id={@id} class="paas-card p-5">
      <h3 class="text-[13px] font-medium text-hd-secondary">Apps by language</h3>
      <p class="text-xs text-hd-muted">{@total} registered on this server</p>
      <div :if={@rows == []} class="py-10 text-center text-[13px] text-hd-muted">
        No apps on this server
      </div>
      <div :if={@rows != []} class="mt-4 space-y-3">
        <.link
          :for={row <- @rows}
          navigate={~p"/apps?runtime=#{row.runtime}"}
          class="group/row block"
          title={"#{row.count} apps · #{row.pct}%"}
        >
          <div class="mb-1 flex items-center justify-between gap-3 text-xs">
            <span class="text-hd-secondary group-hover/row:text-hd-text">{row.label}</span>
            <span class="font-mono tabular-nums text-hd-muted">{row.count}</span>
          </div>
          <div class="h-1.5 rounded-sm bg-hd-raised">
            <div
              class={["h-1.5 rounded-sm", row.lead? && "bg-hd-orange", !row.lead? && "bg-hd-muted/40"]}
              style={"width: #{row.width}%"}
            />
          </div>
        </.link>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :days, :list, required: true

  def deploy_bars(assigns) do
    totals = Enum.map(assigns.days, &(&1.success + &1.failed))
    max_v = totals |> Enum.max(fn -> 1 end) |> max(1)
    total_deploys = Enum.sum(totals)

    success_total = Enum.map(assigns.days, & &1.success) |> Enum.sum()
    failed_total = Enum.map(assigns.days, & &1.failed) |> Enum.sum()

    bar_w = 18
    gap = 4
    slot = bar_w + gap
    width = max(length(assigns.days) * slot, 1)
    height = 96

    bars =
      Enum.with_index(assigns.days, fn day, i ->
        x = i * slot
        total = day.success + day.failed
        total_h = total / max_v * height
        fail_h = if total == 0, do: 0, else: day.failed / max_v * height
        success_h = total_h - fail_h
        y_fail = height - fail_h
        y_ok = y_fail - success_h

        %{
          x: x,
          fail_h: fail_h,
          success_h: success_h,
          y_fail: y_fail,
          y_ok: y_ok,
          label: day.label,
          date: day.date,
          success: day.success,
          failed: day.failed,
          total: total
        }
      end)

    points =
      Enum.map(bars, fn bar ->
        lines =
          if bar.total == 0 do
            ["No deploys"]
          else
            ["#{bar.success} success", "#{bar.failed} failed"]
          end

        %{x: bar.x + bar_w / 2, label: bar.date, lines: lines}
      end)

    assigns =
      assign(assigns,
        bars: bars,
        width: width,
        height: height,
        bar_w: bar_w,
        points: points,
        total_deploys: total_deploys,
        success_total: success_total,
        failed_total: failed_total
      )

    ~H"""
    <section id={@id} class="paas-card p-5">
      <h3 class="text-[13px] font-medium text-hd-secondary">Deploys · 14 days</h3>
      <p :if={@total_deploys > 0} class="text-xs text-hd-muted">
        {@success_total} ok · {@failed_total} failed on this server
      </p>
      <div :if={@total_deploys > 0}>
        <.chart_hover_layer id={"#{@id}-plot"} points={@points} view_width={@width}>
          <svg
            viewBox={"0 0 #{@width} #{@height}"}
            preserveAspectRatio="none"
            class="h-24 w-full"
            role="img"
            aria-label="Deployments last 14 days"
          >
            <g :for={bar <- @bars}>
              <rect
                :if={bar.success_h > 0}
                x={bar.x}
                y={bar.y_ok}
                width={@bar_w}
                height={bar.success_h}
                rx="2"
                fill="var(--color-hd-green)"
              />
              <rect
                :if={bar.fail_h > 0}
                x={bar.x}
                y={bar.y_fail}
                width={@bar_w}
                height={bar.fail_h}
                rx="2"
                fill="var(--color-hd-red)"
              />
              <rect
                x={bar.x}
                y="0"
                width={@bar_w}
                height={@height}
                fill="transparent"
                class="cursor-crosshair"
              />
            </g>
            <line
              x1="0"
              y1={@height}
              x2={@width}
              y2={@height}
              stroke="var(--color-hd-text)"
              stroke-opacity="0.12"
              stroke-width="1"
            />
          </svg>
        </.chart_hover_layer>
      </div>
      <div :if={@total_deploys == 0} class="flex h-28 items-center justify-center">
        <p class="text-[13px] text-hd-muted">No deploys in the last 14 days</p>
      </div>
      <div :if={@total_deploys > 0} id={"#{@id}-labels"} class="mt-1 flex">
        <span
          :for={bar <- @bars}
          class="flex-1 text-center font-mono text-[11px] tabular-nums text-hd-muted"
        >
          {bar.label}
        </span>
      </div>
      <div :if={@total_deploys > 0} class="mt-2 flex gap-4 font-mono text-[11px] text-hd-muted">
        <span class="inline-flex items-center gap-1.5">
          <span class="size-1.5 rounded-full bg-hd-green" /> Success
        </span>
        <span class="inline-flex items-center gap-1.5">
          <span class="size-1.5 rounded-full bg-hd-red" /> Failed
        </span>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :apps, :list, default: []

  def access_bars(assigns) do
    assigns = assign(assigns, rows: ranked_rows(assigns.apps, :requests))

    ~H"""
    <section id={@id} class="paas-card p-5 lg:col-span-2">
      <h3 class="text-[13px] font-medium text-hd-secondary">Most requested · 24h</h3>
      <p class="text-xs text-hd-muted">HTTP requests on this server</p>
      <div :if={@rows == []} class="py-10 text-center text-[13px] text-hd-muted">
        No request samples yet
      </div>
      <div :if={@rows != []} class="mt-4 space-y-3">
        <.link
          :for={row <- @rows}
          id={"#{@id}-#{row.slug}"}
          navigate={~p"/apps/#{row.id}"}
          class="group/row block"
          title={"#{row.value} requests"}
        >
          <div class="mb-1 flex items-center justify-between gap-3 text-xs">
            <span class="truncate text-hd-secondary group-hover/row:text-hd-text">
              {row.name}
            </span>
            <span class="shrink-0 font-mono tabular-nums text-hd-muted">{row.value}</span>
          </div>
          <div class="h-1.5 rounded-sm bg-hd-raised">
            <div
              class={[
                "h-1.5 rounded-sm",
                row.lead? && "bg-hd-orange",
                !row.lead? && "bg-hd-muted/40"
              ]}
              style={"width: #{row.width}%"}
            />
          </div>
        </.link>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :apps, :list, default: []
  attr :stale, :boolean, default: false

  def visited_bars(assigns) do
    assigns = assign(assigns, rows: ranked_rows(assigns.apps, :pageviews))

    ~H"""
    <section id={@id} class="paas-card p-5 lg:col-span-2">
      <h3 class="text-[13px] font-medium text-hd-secondary">
        Most visited · 24h{if(@stale, do: " · stale")}
      </h3>
      <p class="text-xs text-hd-muted">Pageviews on this server</p>
      <div :if={@rows == []} class="py-10 text-center text-[13px] text-hd-muted">
        No pageviews yet
      </div>
      <div :if={@rows != []} class="mt-4 space-y-3">
        <.link
          :for={row <- @rows}
          id={"#{@id}-#{row.slug}"}
          navigate={~p"/apps/#{row.id}?tab=analytics"}
          class="group/row block"
          title={"#{row.value} pageviews"}
        >
          <div class="mb-1 flex items-center justify-between gap-3 text-xs">
            <span class="truncate text-hd-secondary group-hover/row:text-hd-text">
              {row.name}
            </span>
            <span class="shrink-0 font-mono tabular-nums text-hd-muted">{row.value}</span>
          </div>
          <div class="h-1.5 rounded-sm bg-hd-raised">
            <div
              class={[
                "h-1.5 rounded-sm",
                row.lead? && "bg-hd-orange",
                !row.lead? && "bg-hd-muted/40"
              ]}
              style={"width: #{row.width}%"}
            />
          </div>
        </.link>
      </div>
    </section>
    """
  end

  defp ranked_rows(apps, key) do
    values = Enum.map(apps, &Map.get(&1, key))
    peak = values |> Enum.max(fn -> 0 end) |> max(1)

    Enum.map(apps, fn app ->
      value = Map.get(app, key)

      %{
        id: app.id,
        slug: app.slug,
        name: app.name,
        value: value,
        width: max(round(value / peak * 100), if(value > 0, do: 3, else: 0)),
        lead?: value == peak and value > 0
      }
    end)
  end
end
