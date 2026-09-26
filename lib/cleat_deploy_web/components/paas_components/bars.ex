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

  def runtime_bars(assigns) do
    counts = [
      assigns.elixir,
      assigns.gleam,
      assigns.go,
      assigns.js,
      assigns.ruby,
      assigns.rust,
      assigns.static
    ]

    total = max(Enum.sum(counts), 1)
    elixir_pct = round(assigns.elixir / total * 100)
    gleam_pct = round(assigns.gleam / total * 100)
    go_pct = round(assigns.go / total * 100)
    js_pct = round(assigns.js / total * 100)
    ruby_pct = round(assigns.ruby / total * 100)
    rust_pct = round(assigns.rust / total * 100)
    static_pct = round(assigns.static / total * 100)

    assigns =
      assign(assigns,
        elixir_pct: elixir_pct,
        gleam_pct: gleam_pct,
        go_pct: go_pct,
        js_pct: js_pct,
        ruby_pct: ruby_pct,
        rust_pct: rust_pct,
        static_pct: static_pct,
        total: Enum.sum(counts)
      )

    ~H"""
    <section id={@id} class="paas-card p-4">
      <h3 class="font-mono text-[10px] font-semibold uppercase tracking-wider text-hd-muted">
        Apps by language
      </h3>
      <p class="text-[11px] text-hd-muted">{@total} registered on this server</p>
      <div class="mt-5 space-y-4">
        <.link navigate={~p"/apps?runtime=phoenix"} class="group/row block">
          <div class="mb-1 flex items-center justify-between font-mono text-[11px]">
            <span class="text-hd-orange group-hover/row:underline">Elixir</span>
            <span class="tabular-nums text-hd-text">{@elixir}</span>
          </div>
          <div class="group relative h-2 overflow-visible rounded-full bg-hd-aside">
            <div class="h-2 rounded-full bg-hd-orange" style={"width: #{@elixir_pct}%"} />
            <span class="pointer-events-none absolute -top-7 left-1/2 hidden -translate-x-1/2 rounded border border-hd-border bg-hd-card px-2 py-0.5 font-mono text-[10px] text-hd-text shadow-lg group-hover:block">
              {@elixir} apps · {@elixir_pct}%
            </span>
          </div>
        </.link>
        <.link navigate={~p"/apps?runtime=gleam"} class="group/row block">
          <div class="mb-1 flex items-center justify-between font-mono text-[11px]">
            <span class="text-pink-400 group-hover/row:underline">Gleam</span>
            <span class="tabular-nums text-hd-text">{@gleam}</span>
          </div>
          <div class="group relative h-2 overflow-visible rounded-full bg-hd-aside">
            <div class="h-2 rounded-full bg-pink-400" style={"width: #{@gleam_pct}%"} />
            <span class="pointer-events-none absolute -top-7 left-1/2 hidden -translate-x-1/2 rounded border border-hd-border bg-hd-card px-2 py-0.5 font-mono text-[10px] text-hd-text shadow-lg group-hover:block">
              {@gleam} apps · {@gleam_pct}%
            </span>
          </div>
        </.link>
        <.link navigate={~p"/apps?runtime=golang"} class="group/row block">
          <div class="mb-1 flex items-center justify-between font-mono text-[11px]">
            <span class="text-hd-green group-hover/row:underline">Go</span>
            <span class="tabular-nums text-hd-text">{@go}</span>
          </div>
          <div class="group relative h-2 overflow-visible rounded-full bg-hd-aside">
            <div class="h-2 rounded-full bg-hd-green" style={"width: #{@go_pct}%"} />
            <span class="pointer-events-none absolute -top-7 left-1/2 hidden -translate-x-1/2 rounded border border-hd-border bg-hd-card px-2 py-0.5 font-mono text-[10px] text-hd-text shadow-lg group-hover:block">
              {@go} apps · {@go_pct}%
            </span>
          </div>
        </.link>
        <.link navigate={~p"/apps?runtime=node"} class="group/row block">
          <div class="mb-1 flex items-center justify-between font-mono text-[11px]">
            <span class="text-hd-blue group-hover/row:underline">JavaScript</span>
            <span class="tabular-nums text-hd-text">{@js}</span>
          </div>
          <div class="group relative h-2 overflow-visible rounded-full bg-hd-aside">
            <div class="h-2 rounded-full bg-hd-blue" style={"width: #{@js_pct}%"} />
            <span class="pointer-events-none absolute -top-7 left-1/2 hidden -translate-x-1/2 rounded border border-hd-border bg-hd-card px-2 py-0.5 font-mono text-[10px] text-hd-text shadow-lg group-hover:block">
              {@js} apps · {@js_pct}%
            </span>
          </div>
        </.link>
        <.link navigate={~p"/apps?runtime=rails"} class="group/row block">
          <div class="mb-1 flex items-center justify-between font-mono text-[11px]">
            <span class="text-hd-red group-hover/row:underline">Ruby</span>
            <span class="tabular-nums text-hd-text">{@ruby}</span>
          </div>
          <div class="group relative h-2 overflow-visible rounded-full bg-hd-aside">
            <div class="h-2 rounded-full bg-hd-red" style={"width: #{@ruby_pct}%"} />
            <span class="pointer-events-none absolute -top-7 left-1/2 hidden -translate-x-1/2 rounded border border-hd-border bg-hd-card px-2 py-0.5 font-mono text-[10px] text-hd-text shadow-lg group-hover:block">
              {@ruby} apps · {@ruby_pct}%
            </span>
          </div>
        </.link>
        <.link navigate={~p"/apps?runtime=rust"} class="group/row block">
          <div class="mb-1 flex items-center justify-between font-mono text-[11px]">
            <span class="text-amber-500 group-hover/row:underline">Rust</span>
            <span class="tabular-nums text-hd-text">{@rust}</span>
          </div>
          <div class="group relative h-2 overflow-visible rounded-full bg-hd-aside">
            <div class="h-2 rounded-full bg-amber-500" style={"width: #{@rust_pct}%"} />
            <span class="pointer-events-none absolute -top-7 left-1/2 hidden -translate-x-1/2 rounded border border-hd-border bg-hd-card px-2 py-0.5 font-mono text-[10px] text-hd-text shadow-lg group-hover:block">
              {@rust} apps · {@rust_pct}%
            </span>
          </div>
        </.link>
        <.link navigate={~p"/apps?runtime=static"} class="group/row block">
          <div class="mb-1 flex items-center justify-between font-mono text-[11px]">
            <span class="text-hd-muted group-hover/row:underline">Static</span>
            <span class="tabular-nums text-hd-text">{@static}</span>
          </div>
          <div class="group relative h-2 overflow-visible rounded-full bg-hd-aside">
            <div class="h-2 rounded-full bg-hd-muted" style={"width: #{@static_pct}%"} />
            <span class="pointer-events-none absolute -top-7 left-1/2 hidden -translate-x-1/2 rounded border border-hd-border bg-hd-card px-2 py-0.5 font-mono text-[10px] text-hd-text shadow-lg group-hover:block">
              {@static} apps · {@static_pct}%
            </span>
          </div>
        </.link>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :days, :list, required: true

  def deploy_bars(assigns) do
    max_v =
      assigns.days
      |> Enum.map(&(&1.success + &1.failed))
      |> Enum.max(fn -> 1 end)
      |> max(1)

    bar_w = 18
    gap = 2
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
      assign(assigns, bars: bars, width: width, height: height, bar_w: bar_w, points: points)

    ~H"""
    <section id={@id} class="paas-card p-4">
      <h3 class="font-mono text-[10px] font-semibold uppercase tracking-wider text-hd-muted">
        Deploys · 14 days
      </h3>
      <p class="text-[11px] text-hd-muted">Success vs failed on this server</p>
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
              fill="#f85149"
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
        </svg>
      </.chart_hover_layer>
      <div id={"#{@id}-labels"} class="mt-1 flex">
        <span
          :for={bar <- @bars}
          class="flex-1 text-center font-mono text-[9px] tabular-nums text-hd-muted"
        >
          {bar.label}
        </span>
      </div>
      <div class="mt-1 flex gap-3 font-mono text-[10px] text-hd-muted">
        <span class="inline-flex items-center gap-1">
          <span class="size-1.5 rounded-full bg-hd-green" /> Success
        </span>
        <span class="inline-flex items-center gap-1">
          <span class="size-1.5 rounded-full bg-rose-500" /> Failed
        </span>
      </div>
    </section>
    """
  end
end
