defmodule CleatDeployWeb.PaasComponents.Charts do
  @moduledoc false
  use Phoenix.Component

  import CleatDeployWeb.CoreComponents, only: [icon: 1]

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
  attr :points, :list, required: true
  attr :view_width, :integer, required: true
  slot :inner_block, required: true

  def chart_hover_layer(assigns) do
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
end
