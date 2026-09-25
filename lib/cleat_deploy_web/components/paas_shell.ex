defmodule CleatDeployWeb.PaasShell do
  @moduledoc false
  use Phoenix.Component

  import CleatDeployWeb.CoreComponents, only: [icon: 1]
  use CleatDeployWeb, :verified_routes

  attr :flash, :map, required: true
  attr :active_tab, :atom, required: true
  attr :server_count, :integer, default: 0
  attr :app_count, :integer, default: 0
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div id="app-shell" class="paas-shell bg-hd-bg text-hd-text antialiased">
      <header class="paas-shell-header z-40 flex shrink-0 flex-wrap items-center justify-between gap-3 border-b border-hd-border bg-hd-aside px-4 py-3">
        <.link
          href={~p"/"}
          class="group flex items-center gap-2.5 rounded-lg transition-opacity hover:opacity-90"
          aria-label="Back to dashboard"
        >
          <div class="flex size-9 items-center justify-center rounded-lg border border-hd-border bg-hd-card transition-colors group-hover:border-hd-orange/40">
            <.icon name="hero-fire" class="size-5 text-hd-orange" />
          </div>
          <div>
            <div class="flex items-center gap-1.5">
              <h1 class="font-display text-lg font-semibold tracking-tight">Cleat</h1>
              <span class="rounded-full border border-hd-border bg-hd-card px-2 py-0.5 font-mono text-[10px] uppercase tracking-widest text-hd-muted">
                MVP
              </span>
            </div>
            <p class="hidden text-xs text-hd-muted sm:block">
              GitHub → SSH → your VPS
            </p>
          </div>
        </.link>

        <nav class="flex flex-wrap items-center gap-2 text-xs font-medium">
          <.theme_toggle id="theme-toggle" />
          <%= if @current_scope do %>
            <span class="hidden rounded-md border border-hd-border bg-hd-card px-2.5 py-1.5 text-hd-muted sm:inline">
              {@current_scope.user.email}
            </span>
            <.link href={~p"/settings?tab=account"} class="paas-btn-secondary px-3 py-1.5">
              Account
            </.link>
            <.link href={~p"/users/log-out"} method="delete" class="paas-btn-secondary px-3 py-1.5">
              Log out
            </.link>
          <% else %>
            <.link href={~p"/users/log-in"} class="paas-btn-secondary px-3 py-1.5">
              Log in
            </.link>
            <.link
              :if={CleatDeploy.Accounts.registration_allowed?()}
              href={~p"/users/register"}
              class="paas-btn-primary px-3 py-1.5"
            >
              Register
            </.link>
          <% end %>
        </nav>
      </header>

      <aside
        id="app-sidebar"
        class="paas-shell-sidebar flex-col border-r border-hd-border bg-hd-aside"
      >
        <div class="px-4 pt-5 pb-3">
          <p class="font-mono text-[10px] font-semibold tracking-[0.18em] text-hd-muted uppercase">
            Navigate
          </p>
        </div>
        <nav class="flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto px-3" aria-label="Main">
          <.nav_link
            id="nav-dashboard"
            navigate={~p"/"}
            active?={@active_tab == :dashboard}
            icon="hero-squares-2x2"
            label="Dashboard"
          />
          <.nav_link
            id="nav-servers"
            navigate={~p"/servers"}
            active?={@active_tab == :servers}
            icon="hero-server-stack"
            label="Servers"
            count={@server_count}
          />
          <.nav_link
            id="nav-apps"
            navigate={~p"/apps"}
            active?={@active_tab == :apps}
            icon="hero-globe-alt"
            label="App Details"
            count={@app_count}
          />
          <.nav_link
            id="nav-settings"
            navigate={~p"/settings"}
            active?={@active_tab == :settings}
            icon="hero-cog-6-tooth"
            label="Settings"
          />
        </nav>
        <div
          id="app-sidebar-actions"
          class="mt-auto shrink-0 space-y-2 border-t border-hd-border px-3 py-4"
        >
          <.link navigate={~p"/servers/new"} class="paas-btn-secondary w-full justify-center">
            <.icon name="hero-plus" class="size-3.5 text-hd-orange" /> New VM
          </.link>
          <.link navigate={~p"/apps/new"} class="paas-btn-primary w-full justify-center">
            <.icon name="hero-plus" class="size-3.5" /> Register App
          </.link>
        </div>
      </aside>

      <div class="paas-shell-main flex flex-col">
        <div class="flex shrink-0 items-center justify-between gap-3 border-b border-hd-border bg-hd-bg px-3 py-3 lg:hidden">
          <nav
            id="app-nav-mobile"
            class="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto rounded-lg border border-hd-border bg-hd-aside p-1"
          >
            <.nav_link
              id="nav-dashboard-mobile"
              navigate={~p"/"}
              active?={@active_tab == :dashboard}
              icon="hero-squares-2x2"
              label="Dashboard"
              compact
            />
            <.nav_link
              id="nav-servers-mobile"
              navigate={~p"/servers"}
              active?={@active_tab == :servers}
              icon="hero-server-stack"
              label="Servers"
              count={@server_count}
              compact
            />
            <.nav_link
              id="nav-apps-mobile"
              navigate={~p"/apps"}
              active?={@active_tab == :apps}
              icon="hero-globe-alt"
              label="Apps"
              count={@app_count}
              compact
            />
            <.nav_link
              id="nav-settings-mobile"
              navigate={~p"/settings"}
              active?={@active_tab == :settings}
              icon="hero-cog-6-tooth"
              label="Settings"
              compact
            />
          </nav>
        </div>

        <main class="relative flex min-h-0 flex-1 flex-col overflow-hidden">
          <div class="paas-grid-bg pointer-events-none absolute inset-0 opacity-[0.03]" />
          <div class="relative z-10 min-h-0 flex-1 overflow-y-auto overscroll-contain p-4 lg:p-6">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <footer
        id="app-footer"
        class="paas-shell-footer shrink-0 border-t border-hd-border bg-hd-aside px-4 py-3.5 text-xs text-hd-muted select-none"
      >
        <div class="mx-auto flex max-w-7xl flex-col items-center justify-between gap-3 md:flex-row">
          <div class="flex items-center gap-1.5">
            <.icon name="hero-fire" class="size-3.5 text-hd-orange" />
            <span class="font-mono text-[10px] font-semibold tracking-wider text-hd-text">
              PHOENIX PAAS CLUSTER MGMT
            </span>
            <span class="rounded-full border border-hd-border bg-hd-card px-2 py-0.5 text-[10px]">
              v0.1.0-alpha
            </span>
          </div>
          <div class="flex items-center gap-3 font-mono text-[10px]">
            <span>Hetzner · fsn1</span>
            <span class="text-hd-green">Node Sync: ONLINE</span>
          </div>
        </div>
      </footer>

      <.flash_toast flash={@flash} />
    </div>
    """
  end

  attr :id, :string, default: "theme-toggle"

  def theme_toggle(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-hook="ThemeToggle"
      phx-update="ignore"
      class="paas-btn-secondary size-9 justify-center px-0"
      aria-label="Switch to light mode"
      aria-pressed="false"
      title="Light mode"
    >
      <span data-theme-icon="sun">
        <.icon name="hero-sun" class="size-4" />
      </span>
      <span data-theme-icon="moon" class="hidden">
        <.icon name="hero-moon" class="size-4" />
      </span>
    </button>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :active?, :boolean, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :count, :integer, default: nil
  attr :compact, :boolean, default: false

  defp nav_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class={[
        "group flex items-center gap-2 rounded-lg text-xs font-semibold tracking-wide transition-all",
        @compact && "px-2.5 py-1.5",
        !@compact && "px-3 py-2.5",
        @active? && "bg-hd-card text-hd-orange shadow-sm ring-1 ring-hd-border",
        !@active? && "text-hd-muted hover:bg-hd-card/70 hover:text-hd-text"
      ]}
    >
      <.icon name={@icon} class="size-4 shrink-0" />
      <span class="min-w-0 truncate">{@label}</span>
      <span
        :if={@count != nil}
        class={[
          "ml-auto rounded-md px-1.5 py-0.5 font-mono text-[10px]",
          @active? && "bg-hd-orange/10 text-hd-orange",
          !@active? && "bg-hd-card text-hd-muted ring-1 ring-hd-border"
        ]}
      >
        {@count}
      </span>
    </.link>
    """
  end

  attr :flash, :map, required: true

  defp flash_toast(assigns) do
    ~H"""
    <div
      id="flash-toast"
      aria-live="polite"
      class="pointer-events-none fixed top-20 left-1/2 z-50 -translate-x-1/2"
    >
      <div
        :if={msg = Phoenix.Flash.get(@flash, :info)}
        class="flex items-center gap-2 rounded-md border border-hd-green bg-hd-card px-3 py-2 font-mono text-[11px] font-medium text-hd-green shadow-xl"
      >
        <span class="size-1.5 rounded-full bg-hd-green" />
        {msg}
      </div>
      <div
        :if={msg = Phoenix.Flash.get(@flash, :error)}
        class="flex items-center gap-2 rounded-md border border-hd-orange bg-hd-card px-3 py-2 font-mono text-[11px] font-medium text-hd-orange shadow-xl"
      >
        <span class="size-1.5 rounded-full bg-hd-orange" />
        {msg}
      </div>
    </div>
    """
  end
end
