defmodule CleatDeployWeb.AppLive.Index.Filters do
  @moduledoc false
  use CleatDeployWeb, :html

  def bar(assigns) do
    ~H"""
    <div class="space-y-2.5 border-b border-hd-border bg-hd-aside/40 px-4 py-3">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <.form
          for={to_form(%{"query" => @apps_query})}
          id="apps-filter"
          phx-change="filter_apps"
          class="min-w-0 flex-1"
        >
          <label class="relative block max-w-md">
            <span class="sr-only">Filter applications</span>
            <.icon
              name="hero-magnifying-glass"
              class="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-hd-muted"
            />
            <input
              type="search"
              name="query"
              id="apps-query"
              value={@apps_query}
              phx-debounce="150"
              placeholder="Filter by name, host, language, or server"
              class="paas-input w-full pl-9"
            />
          </label>
        </.form>
        <div class="flex flex-wrap items-center gap-1.5">
          <.runtime_filter_chip id="apps-filter-all" runtime={:all} current={@apps_runtime}>
            All
          </.runtime_filter_chip>
          <.runtime_filter_chip
            id="apps-filter-phoenix"
            runtime={:phoenix}
            current={@apps_runtime}
          >
            Elixir
          </.runtime_filter_chip>
          <.runtime_filter_chip
            id="apps-filter-golang"
            runtime={:golang}
            current={@apps_runtime}
          >
            Go
          </.runtime_filter_chip>
          <.runtime_filter_chip
            id="apps-filter-node"
            runtime={:node}
            current={@apps_runtime}
          >
            JS
          </.runtime_filter_chip>
          <.runtime_filter_chip
            id="apps-filter-rails"
            runtime={:rails}
            current={@apps_runtime}
          >
            Ruby
          </.runtime_filter_chip>
          <.runtime_filter_chip
            id="apps-filter-rust"
            runtime={:rust}
            current={@apps_runtime}
          >
            Rust
          </.runtime_filter_chip>
          <.runtime_filter_chip
            id="apps-filter-static"
            runtime={:static}
            current={@apps_runtime}
          >
            Static
          </.runtime_filter_chip>
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
        <div class="flex flex-wrap items-center gap-1.5">
          <span class="font-mono text-[9px] font-semibold tracking-wider text-hd-muted uppercase">
            Idle
          </span>
          <.filter_chip
            id="apps-filter-idle-all"
            event="filter_idle"
            value={:all}
            current={@apps_idle}
          >
            All
          </.filter_chip>
          <.filter_chip
            id="apps-filter-idle-on"
            event="filter_idle"
            value={:on}
            current={@apps_idle}
          >
            Opt-in
          </.filter_chip>
          <.filter_chip
            id="apps-filter-idle-off"
            event="filter_idle"
            value={:off}
            current={@apps_idle}
          >
            Not opt-in
          </.filter_chip>
        </div>

        <div class="flex flex-wrap items-center gap-1.5">
          <span class="font-mono text-[9px] font-semibold tracking-wider text-hd-muted uppercase">
            Status
          </span>
          <.filter_chip
            id="apps-filter-state-all"
            event="filter_state"
            value={:all}
            current={@apps_state}
          >
            All
          </.filter_chip>
          <.filter_chip
            id="apps-filter-state-on"
            event="filter_state"
            value={:on}
            current={@apps_state}
          >
            On
          </.filter_chip>
          <.filter_chip
            id="apps-filter-state-off"
            event="filter_state"
            value={:off}
            current={@apps_state}
          >
            Off
          </.filter_chip>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :value, :atom, required: true
  attr :current, :atom, required: true
  slot :inner_block, required: true

  def filter_chip(assigns) do
    assigns = assign(assigns, :active?, assigns.value == assigns.current)

    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@event}
      phx-value-value={@value}
      class={[
        "rounded-md border px-2.5 py-1 font-mono text-[10px] font-semibold uppercase tracking-wide transition-colors",
        @active? && "border-hd-orange/50 bg-hd-orange/10 text-hd-orange",
        not @active? &&
          "border-hd-border bg-hd-card text-hd-muted hover:border-hd-orange/40 hover:text-hd-text"
      ]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :id, :string, required: true
  attr :runtime, :atom, required: true
  attr :current, :atom, required: true
  slot :inner_block, required: true

  def runtime_filter_chip(assigns) do
    active? = assigns.runtime == assigns.current
    assigns = assign(assigns, :active?, active?)

    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="filter_runtime"
      phx-value-runtime={@runtime}
      class={[
        "rounded-md border px-2.5 py-1 font-mono text-[10px] font-semibold uppercase tracking-wide transition-colors",
        @active? && "border-hd-orange/50 bg-hd-orange/10 text-hd-orange",
        not @active? &&
          "border-hd-border bg-hd-card text-hd-muted hover:border-hd-orange/40 hover:text-hd-text"
      ]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end
end
