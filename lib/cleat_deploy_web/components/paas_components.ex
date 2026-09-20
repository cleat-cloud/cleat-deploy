defmodule CleatDeployWeb.PaasComponents do
  @moduledoc false
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  import CleatDeployWeb.CoreComponents, only: [icon: 1]

  alias CleatDeploy.Apps.App

  @repo_picker_limit 50

  attr :app, App, required: true

  def language_badge(assigns) do
    language = App.main_language(assigns.app)
    badge_classes = language_badge_classes(assigns.app.runtime)

    assigns = assign(assigns, language: language, badge_classes: badge_classes)

    ~H"""
    <span
      id={"app-#{@app.id}-language"}
      class={[
        "inline-flex items-center rounded border px-2 py-0.5 font-mono text-[10px] font-semibold uppercase tracking-wide",
        @badge_classes
      ]}
    >
      {@language}
    </span>
    """
  end

  defp language_badge_classes("golang"), do: "border-hd-green/40 bg-hd-green/10 text-hd-green"
  defp language_badge_classes("node"), do: "border-hd-blue/40 bg-hd-blue/10 text-hd-blue"
  defp language_badge_classes(_runtime), do: "border-hd-orange/40 bg-hd-orange/10 text-hd-orange"

  attr :app, App, required: true
  attr :memory, :any, default: nil

  def ram_cell(assigns) do
    peak = CleatDeploy.Apps.RuntimeMemory.format_peak(assigns.memory)

    assigns =
      assign(assigns, peak: peak, label: CleatDeploy.Apps.RuntimeMemory.format(assigns.memory))

    ~H"""
    <span
      id={"app-#{@app.id}-ram"}
      class="font-mono text-sm tabular-nums text-hd-text"
      title={@peak}
    >
      {@label}
    </span>
    """
  end

  attr :app, App, required: true
  attr :memory, :any, default: nil

  def cpu_cell(assigns) do
    assigns = assign(assigns, label: CleatDeploy.Apps.RuntimeMemory.format_cpu(assigns.memory))

    ~H"""
    <span
      id={"app-#{@app.id}-cpu"}
      class="font-mono text-sm tabular-nums text-hd-text"
      title="Share of one vCPU"
    >
      {@label}
    </span>
    """
  end

  attr :app, App, required: true
  attr :memory, :any, default: nil

  def disk_cell(assigns) do
    assigns = assign(assigns, label: CleatDeploy.Apps.RuntimeMemory.format_disk(assigns.memory))

    ~H"""
    <span
      id={"app-#{@app.id}-disk"}
      class="font-mono text-sm tabular-nums text-hd-text"
      title="Release + data"
    >
      {@label}
    </span>
    """
  end

  attr :status, :atom, required: true

  def deploy_status_badge(assigns) do
    {class, pulse?, label} =
      case assigns.status do
        :queued -> {"text-hd-orange", true, "queued"}
        :running -> {"text-sky-400", true, "running"}
        :success -> {"text-hd-green", false, "success"}
        :failed -> {"text-rose-500", false, "failed"}
      end

    assigns = assign(assigns, class: class, pulse?: pulse?, label: label)

    ~H"""
    <span class={["inline-flex items-center gap-1.5 font-mono text-xs capitalize", @class]}>
      <span
        :if={@pulse?}
        class={[
          "size-1.5 rounded-full bg-current",
          @status == :queued && "animate-ping",
          @status == :running && "animate-pulse"
        ]}
      />
      <span :if={not @pulse?} class="size-1.5 rounded-full bg-current" />
      {@label}
    </span>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :mono, :boolean, default: false
  attr :hidden?, :boolean, default: false

  def copy_field(assigns) do
    ~H"""
    <div class="space-y-1">
      <span
        :if={@label != ""}
        class="font-mono text-[9px] font-semibold uppercase tracking-wider text-hd-muted"
      >
        {@label}
      </span>
      <div class="flex items-center justify-between gap-2 rounded border border-hd-border bg-hd-aside px-2.5 py-1.5 text-xs">
        <span class={["min-w-0 flex-1 truncate font-medium text-hd-text", @mono && "font-mono"]}>
          {if @hidden?, do: String.duplicate("•", 32), else: @value}
        </span>
        <button
          :if={not @hidden?}
          id={"copy-#{@id}"}
          type="button"
          phx-hook=".Copy"
          data-clipboard={@value}
          class="shrink-0 text-hd-muted transition-colors hover:text-hd-orange"
          aria-label={"Copy #{@label}"}
        >
          <.icon name="hero-clipboard-document" class="size-3.5" />
        </button>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".Copy">
          export default {
            mounted() {
              this.el.addEventListener("click", () => {
                const text = this.el.dataset.clipboard || "";
                navigator.clipboard.writeText(text).then(() => {
                  this.el.classList.add("text-hd-green");
                  setTimeout(() => this.el.classList.remove("text-hd-green"), 1200);
                });
              });
            }
          }
        </script>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil
  attr :icon, :string, default: "hero-server-stack"

  def metric_card(assigns) do
    ~H"""
    <div class="paas-card group flex cursor-pointer items-center justify-between p-4 transition-all hover:border-hd-orange/40">
      <div class="space-y-0.5">
        <p class="block font-mono text-[10px] font-semibold uppercase tracking-wider text-hd-muted">
          {@title}
        </p>
        <div class="flex items-baseline gap-1.5">
          <p class="font-mono text-2xl font-bold tabular-nums text-hd-text">{@value}</p>
          <p :if={@hint} class="font-sans text-[11px] text-hd-muted">{@hint}</p>
        </div>
      </div>
      <div class="flex size-9 items-center justify-center rounded border border-hd-border bg-hd-aside transition-colors">
        <.icon
          name={@icon}
          class="size-5 text-hd-orange transition-transform group-hover:scale-110"
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :current, :string, default: nil
  attr :hint, :string, default: nil
  attr :live?, :boolean, default: false
  attr :series, :list, default: []
  attr :color, :string, default: "var(--color-hd-orange)"

  def area_chart(assigns) do
    {fill, line} = series_paths(assigns.series, 400, 128)
    points = hover_points(assigns.series, 400, &format_cpu/1)
    assigns = assign(assigns, fill: fill, line: line, points: points)

    ~H"""
    <section id={@id} class="paas-card p-4">
      <div class="flex items-baseline justify-between gap-3">
        <div>
          <h3 class="font-mono text-[10px] font-semibold uppercase tracking-wider text-hd-muted">
            {@title}
          </h3>
          <p :if={@hint} class="text-[11px] text-hd-muted">{@hint}</p>
        </div>
        <p
          :if={@current}
          id={"#{@id}-current"}
          class="flex items-center gap-2 font-mono text-lg font-semibold tabular-nums text-hd-text"
        >
          <span
            :if={@live?}
            class="size-1.5 rounded-full bg-hd-green motion-safe:animate-pulse"
            aria-hidden="true"
          />
          {@current}
        </p>
      </div>
      <.chart_hover_layer
        :if={@line != ""}
        id={"#{@id}-plot"}
        points={@points}
        view_width={400}
      >
        <svg viewBox="0 0 400 128" class="h-28 w-full overflow-visible" role="img" aria-label={@title}>
          <path d={@fill} fill={@color} fill-opacity="0.16" />
          <path d={@line} fill="none" stroke={@color} stroke-width="2" stroke-linejoin="round" />
          <rect x="0" y="0" width="400" height="128" fill="transparent" class="cursor-crosshair" />
        </svg>
      </.chart_hover_layer>
      <p :if={@line == ""} class="mt-8 text-center font-mono text-[11px] text-hd-muted">
        No samples yet
      </p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :current, :string, default: nil
  attr :hint, :string, default: nil
  attr :live?, :boolean, default: false
  attr :inbound, :list, default: []
  attr :outbound, :list, default: []

  def dual_line_chart(assigns) do
    max_v =
      (assigns.inbound ++ assigns.outbound)
      |> Enum.map(& &1.v)
      |> Enum.max(fn -> 1.0 end)
      |> max(1.0)

    {_fill_in, line_in} = series_paths(assigns.inbound, 400, 128, max_v)
    {_fill_out, line_out} = series_paths(assigns.outbound, 400, 128, max_v)
    points = dual_hover_points(assigns.inbound, assigns.outbound, 400)

    assigns = assign(assigns, line_in: line_in, line_out: line_out, points: points)

    ~H"""
    <section id={@id} class="paas-card p-4">
      <div class="flex items-baseline justify-between gap-3">
        <div>
          <h3 class="font-mono text-[10px] font-semibold uppercase tracking-wider text-hd-muted">
            {@title}
          </h3>
          <p :if={@hint} class="text-[11px] text-hd-muted">{@hint}</p>
        </div>
        <p
          :if={@current}
          id={"#{@id}-current"}
          class="flex items-center gap-2 font-mono text-sm font-semibold tabular-nums text-hd-text"
        >
          <span
            :if={@live?}
            class="size-1.5 rounded-full bg-hd-green motion-safe:animate-pulse"
            aria-hidden="true"
          />
          {@current}
        </p>
      </div>
      <.chart_hover_layer
        :if={@line_in != "" or @line_out != ""}
        id={"#{@id}-plot"}
        points={@points}
        view_width={400}
      >
        <svg viewBox="0 0 400 128" class="h-28 w-full overflow-visible" role="img" aria-label={@title}>
          <path
            :if={@line_in != ""}
            d={@line_in}
            fill="none"
            stroke="var(--color-hd-orange)"
            stroke-width="2"
            stroke-linejoin="round"
          />
          <path
            :if={@line_out != ""}
            d={@line_out}
            fill="none"
            stroke="var(--color-hd-green)"
            stroke-width="2"
            stroke-linejoin="round"
          />
          <rect x="0" y="0" width="400" height="128" fill="transparent" class="cursor-crosshair" />
        </svg>
      </.chart_hover_layer>
      <div class="mt-2 flex gap-3 font-mono text-[10px] text-hd-muted">
        <span class="inline-flex items-center gap-1">
          <span class="size-1.5 rounded-full bg-hd-orange" /> In
        </span>
        <span class="inline-flex items-center gap-1">
          <span class="size-1.5 rounded-full bg-hd-green" /> Out
        </span>
      </div>
      <p
        :if={@line_in == "" and @line_out == ""}
        class="mt-8 text-center font-mono text-[11px] text-hd-muted"
      >
        No samples yet
      </p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :elixir, :integer, required: true
  attr :go, :integer, required: true
  attr :js, :integer, required: true

  def runtime_bars(assigns) do
    total = max(assigns.elixir + assigns.go + assigns.js, 1)
    elixir_pct = round(assigns.elixir / total * 100)
    go_pct = round(assigns.go / total * 100)
    js_pct = round(assigns.js / total * 100)

    assigns =
      assign(assigns,
        elixir_pct: elixir_pct,
        go_pct: go_pct,
        js_pct: js_pct,
        total: assigns.elixir + assigns.go + assigns.js
      )

    ~H"""
    <section id={@id} class="paas-card p-4">
      <h3 class="font-mono text-[10px] font-semibold uppercase tracking-wider text-hd-muted">
        Apps by language
      </h3>
      <p class="text-[11px] text-hd-muted">{@total} registered on this tenant</p>
      <div class="mt-5 space-y-4">
        <div>
          <div class="mb-1 flex items-center justify-between font-mono text-[11px]">
            <span class="text-hd-orange">Elixir</span>
            <span class="tabular-nums text-hd-text">{@elixir}</span>
          </div>
          <div class="group relative h-2 overflow-visible rounded-full bg-hd-aside">
            <div class="h-2 rounded-full bg-hd-orange" style={"width: #{@elixir_pct}%"} />
            <span class="pointer-events-none absolute -top-7 left-1/2 hidden -translate-x-1/2 rounded border border-hd-border bg-hd-card px-2 py-0.5 font-mono text-[10px] text-hd-text shadow-lg group-hover:block">
              {@elixir} apps · {@elixir_pct}%
            </span>
          </div>
        </div>
        <div>
          <div class="mb-1 flex items-center justify-between font-mono text-[11px]">
            <span class="text-hd-green">Go</span>
            <span class="tabular-nums text-hd-text">{@go}</span>
          </div>
          <div class="group relative h-2 overflow-visible rounded-full bg-hd-aside">
            <div class="h-2 rounded-full bg-hd-green" style={"width: #{@go_pct}%"} />
            <span class="pointer-events-none absolute -top-7 left-1/2 hidden -translate-x-1/2 rounded border border-hd-border bg-hd-card px-2 py-0.5 font-mono text-[10px] text-hd-text shadow-lg group-hover:block">
              {@go} apps · {@go_pct}%
            </span>
          </div>
        </div>
        <div>
          <div class="mb-1 flex items-center justify-between font-mono text-[11px]">
            <span class="text-hd-blue">JavaScript</span>
            <span class="tabular-nums text-hd-text">{@js}</span>
          </div>
          <div class="group relative h-2 overflow-visible rounded-full bg-hd-aside">
            <div class="h-2 rounded-full bg-hd-blue" style={"width: #{@js_pct}%"} />
            <span class="pointer-events-none absolute -top-7 left-1/2 hidden -translate-x-1/2 rounded border border-hd-border bg-hd-card px-2 py-0.5 font-mono text-[10px] text-hd-text shadow-lg group-hover:block">
              {@js} apps · {@js_pct}%
            </span>
          </div>
        </div>
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
      <p class="text-[11px] text-hd-muted">Success vs failed across all apps</p>
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

  attr :id, :string, required: true
  attr :points, :list, required: true
  attr :view_width, :integer, required: true
  slot :inner_block, required: true

  defp chart_hover_layer(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="ChartTip"
      data-points={Jason.encode!(@points)}
      data-view-width={@view_width}
      class="relative mt-3"
    >
      {render_slot(@inner_block)}
      <div
        data-chart-line
        class="pointer-events-none absolute top-0 hidden h-[calc(100%-0.25rem)] w-px bg-hd-text/35"
      >
      </div>
      <div
        data-chart-tip
        class="pointer-events-none absolute top-1 z-20 hidden min-w-28 rounded border border-hd-border bg-hd-card px-2 py-1.5 shadow-lg"
      >
        <p data-chart-tip-label class="font-mono text-[10px] text-hd-muted"></p>
        <p
          data-chart-tip-value
          class="whitespace-pre-line font-mono text-[11px] font-semibold tabular-nums text-hd-text"
        >
        </p>
      </div>
    </div>
    """
  end

  defp hover_points(series, w, formatter) when is_list(series) and length(series) >= 2 do
    n = length(series)
    step = w / (n - 1)

    Enum.with_index(series, fn point, i ->
      %{
        x: Float.round(i * step, 1),
        label: format_sample_time(Map.get(point, :t)),
        lines: [formatter.(point.v)]
      }
    end)
  end

  defp hover_points(_, _, _), do: []

  defp dual_hover_points(inbound, outbound, w)
       when is_list(inbound) and is_list(outbound) and inbound != [] and outbound != [] do
    pairs = Enum.zip(inbound, outbound)
    n = length(pairs)

    if n < 2 do
      []
    else
      step = w / (n - 1)

      Enum.with_index(pairs, fn {incoming, outgoing}, i ->
        %{
          x: Float.round(i * step, 1),
          label: format_sample_time(Map.get(incoming, :t) || Map.get(outgoing, :t)),
          lines: ["In #{format_bps(incoming.v)}", "Out #{format_bps(outgoing.v)}"]
        }
      end)
    end
  end

  defp dual_hover_points(_, _, _), do: []

  defp format_sample_time(t) when is_integer(t) do
    case DateTime.from_unix(t) do
      {:ok, dt} -> Calendar.strftime(dt, "%H:%M UTC")
      _ -> "—"
    end
  end

  defp format_sample_time(_), do: "—"

  defp format_cpu(nil), do: "—"

  defp format_cpu(value) when is_number(value),
    do: :erlang.float_to_binary(value / 1, decimals: 1) <> "%"

  defp format_bps(nil), do: "—"

  defp format_bps(v) when v >= 1_000_000,
    do: :erlang.float_to_binary(v / 1_000_000, decimals: 1) <> " MB/s"

  defp format_bps(v) when v >= 1_000,
    do: :erlang.float_to_binary(v / 1_000, decimals: 1) <> " KB/s"

  defp format_bps(v) when is_number(v), do: :erlang.float_to_binary(v / 1, decimals: 1) <> " B/s"

  defp series_paths(series, w, h, max_v \\ nil)
  defp series_paths(series, _w, _h, _max_v) when not is_list(series) or series == [], do: {"", ""}

  defp series_paths(series, w, h, max_v) do
    n = length(series)

    if n < 2 do
      {"", ""}
    else
      peak =
        max_v ||
          series
          |> Enum.map(& &1.v)
          |> Enum.max()
          |> max(1.0)

      pad = 4
      usable = h - pad * 2
      step = w / (n - 1)

      pts =
        series
        |> Enum.with_index()
        |> Enum.map(fn {%{v: v}, i} ->
          x = Float.round(i * step, 1)
          y = Float.round(pad + usable * (1 - v / peak), 1)
          {x, y}
        end)

      [{x0, _} | _] = pts
      {xn, _} = List.last(pts)

      line =
        pts
        |> Enum.with_index()
        |> Enum.map(fn {{x, y}, i} ->
          if i == 0, do: "M #{x} #{y}", else: "L #{x} #{y}"
        end)
        |> Enum.join(" ")

      fill = line <> " L #{xn} #{h} L #{x0} #{h} Z"
      {fill, line}
    end
  end

  attr :id, :string, default: "deploy-terminal"
  attr :deployment, :map, required: true
  attr :active?, :boolean, default: false
  attr :duration, :string, default: nil

  def deploy_terminal(assigns) do
    lines =
      assigns.deployment.log
      |> to_string()
      |> String.split("\n", trim: true)

    assigns = assign(assigns, :lines, lines)

    ~H"""
    <div
      id={@id}
      class="overflow-hidden rounded-md border border-hd-border bg-hd-bg font-mono text-[11px] text-hd-text"
    >
      <div class="flex items-center justify-between border-b border-hd-border bg-hd-aside px-3 py-1.5">
        <div class="flex items-center gap-1.5">
          <.icon name="hero-command-line" class="size-3.5 text-hd-orange" />
          <span class="text-[10px] font-semibold tracking-wider text-hd-muted">
            BUILD CONTAINER SHELL
          </span>
          <span class="rounded border border-hd-border bg-hd-card px-1 py-0.5 font-mono text-[9px] text-hd-muted">
            SHA: {@deployment.git_sha}
          </span>
        </div>
        <.deploy_status_badge status={@deployment.status} />
      </div>

      <div
        id="deploy-terminal-body"
        phx-hook=".TerminalScroll"
        class="h-56 overflow-auto p-3 font-mono text-[11px] leading-5"
      >
        <div :if={@lines == []} class="text-hd-muted">Waiting for build output…</div>
        <div :for={{line, index} <- Enum.with_index(@lines)} class="flex items-start">
          <span class="sticky left-0 z-10 mr-3 w-8 shrink-0 select-none bg-hd-bg pr-1 text-right tabular-nums text-hd-muted/40">
            {String.pad_leading(Integer.to_string(index + 1), 2, "0")}
          </span>
          <span class={["min-w-0 whitespace-pre", terminal_line_class(line)]}>{line}</span>
        </div>
        <span :if={@active?} class="ml-8 inline-block h-3 w-1 animate-pulse bg-hd-orange" />
        <script :type={Phoenix.LiveView.ColocatedHook} name=".TerminalScroll">
          export default {
            mounted() { this.scroll(); },
            updated() { this.scroll(); },
            scroll() {
              this.el.scrollTop = this.el.scrollHeight;
            }
          }
        </script>
      </div>

      <div class="flex items-center justify-between border-t border-hd-border bg-hd-aside px-3 py-1 text-[10px] text-hd-muted">
        <div class="flex items-center gap-2">
          <span>Elixir 1.16.2</span>
          <span>OTP 26.2.1</span>
          <span>Phoenix 1.7.12</span>
        </div>
        <div class="flex items-center gap-3">
          <span :if={@duration && @duration != "—"} class="tabular-nums text-hd-text">
            {@duration}
          </span>
          <span>Target VM: us-east-1</span>
        </div>
      </div>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :repos, :list, required: true
  attr :repo_search, :string, default: ""
  attr :open?, :boolean, default: false

  def github_repo_picker(assigns) do
    selected = to_string(assigns.field.value || "")
    filtered = filter_repo_options(assigns.repos, assigns.repo_search, @repo_picker_limit)
    total_matches = count_repo_matches(assigns.repos, assigns.repo_search)

    assigns =
      assigns
      |> assign(:selected, selected)
      |> assign(:filtered, filtered)
      |> assign(:total_matches, total_matches)
      |> assign(
        :search_display,
        repo_search_display(assigns.open?, assigns.repo_search, selected)
      )
      |> assign(:errors, assigns.field.errors)

    ~H"""
    <div
      id="github-repo-picker"
      class="fieldset relative mb-2"
      phx-click-away={JS.push("close_repo_picker")}
    >
      <label for="github-repo-search">
        <span class="label mb-1">GitHub repository</span>
        <div class="relative">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-hd-muted"
          />
          <input
            type="text"
            id="github-repo-search"
            name="repo_search"
            value={@search_display}
            phx-focus="open_repo_picker"
            phx-keyup="search_repos"
            phx-debounce="150"
            placeholder="Search repositories…"
            autocomplete="off"
            class={[
              "paas-input w-full pl-9",
              @errors != [] && "border-rose-500"
            ]}
          />
          <input type="hidden" name={@field.name} id={@field.id} value={@selected} />
        </div>
      </label>

      <ul
        :if={@open?}
        id="github-repo-options"
        class="absolute z-20 mt-1 max-h-56 w-full overflow-y-auto rounded-md border border-hd-border bg-hd-card shadow-xl"
      >
        <li :if={@filtered == []} class="px-3 py-2 text-xs text-hd-muted">
          No repositories match your search.
        </li>
        <li :for={{label, value} <- @filtered} id={"github-repo-option-#{slugify_option_id(value)}"}>
          <button
            type="button"
            phx-click="pick_repo"
            phx-value-repo={value}
            class={[
              "flex w-full items-center px-3 py-2 text-left font-mono text-xs transition-colors hover:bg-hd-aside",
              @selected == value && "bg-hd-aside/80 text-hd-orange"
            ]}
          >
            {label}
          </button>
        </li>
        <li
          :if={@total_matches > @repo_picker_limit}
          class="border-t border-hd-border px-3 py-2 text-[10px] text-hd-muted"
        >
          Showing first 50 of {@total_matches} matches. Refine your search.
        </li>
      </ul>

      <p :for={msg <- @errors} class="mt-1 text-xs text-rose-400">
        {translate_form_error(msg)}
      </p>
    </div>
    """
  end

  @doc false
  def filter_repo_options(repos, query, limit \\ @repo_picker_limit) do
    repos
    |> matching_repo_options(query)
    |> Enum.take(limit)
  end

  @doc false
  def count_repo_matches(repos, query) do
    repos |> matching_repo_options(query) |> length()
  end

  defp matching_repo_options(repos, query) do
    query = String.downcase(String.trim(to_string(query || "")))

    Enum.filter(repos, fn {label, _value} ->
      query == "" or String.contains?(String.downcase(label), query)
    end)
  end

  defp repo_search_display(true, repo_search, _selected), do: repo_search

  defp repo_search_display(false, _repo_search, selected) when selected != "",
    do: selected

  defp repo_search_display(false, repo_search, _selected), do: repo_search

  defp translate_form_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp translate_form_error(msg) when is_binary(msg), do: msg

  defp slugify_option_id(value) do
    value
    |> String.replace("/", "-")
    |> String.replace(~r/[^a-zA-Z0-9-]+/u, "-")
  end

  attr :label, :string, required: true
  attr :id, :string, default: nil
  attr :value, :string, required: true
  attr :mono, :boolean, default: false
  attr :sub, :string, default: nil
  attr :href, :string, default: nil

  def info_tile(%{href: href} = assigns) when is_binary(href) do
    ~H"""
    <.link
      id={@id}
      navigate={@href}
      class="paas-card flex flex-col justify-between space-y-1 p-3 transition-colors hover:border-hd-orange/50"
    >
      <span class="font-mono text-[9px] font-bold uppercase tracking-widest text-hd-muted">
        {@label}
      </span>
      <p class={["truncate text-xs font-semibold text-hd-text", @mono && "font-mono"]}>{@value}</p>
      <p :if={@sub} class="block font-mono text-[10px] text-hd-orange">{@sub}</p>
    </.link>
    """
  end

  def info_tile(assigns) do
    ~H"""
    <div id={@id} class="paas-card flex flex-col justify-between space-y-1 p-3">
      <span class="font-mono text-[9px] font-bold uppercase tracking-widest text-hd-muted">
        {@label}
      </span>
      <p class={["truncate text-xs font-semibold text-hd-text", @mono && "font-mono"]}>{@value}</p>
      <p :if={@sub} class="block font-mono text-[10px] text-hd-muted">{@sub}</p>
    </div>
    """
  end

  defp terminal_line_class(line) do
    cond do
      String.starts_with?(line, "==>") ->
        "font-semibold text-hd-orange"

      String.starts_with?(line, "$") ->
        "text-hd-muted"

      String.contains?(line, "SUCCESS") or String.contains?(line, "successful") ->
        "text-hd-green"

      String.contains?(line, "FAIL") or String.contains?(line, "Error") ->
        "font-medium text-rose-500"

      true ->
        "text-hd-text"
    end
  end
end
