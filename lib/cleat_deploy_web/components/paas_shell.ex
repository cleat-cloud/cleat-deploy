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
      <header class="paas-shell-header z-40 flex shrink-0 flex-wrap items-center justify-between gap-3 border-b border-hd-border bg-hd-aside px-4 py-2.5">
        <.link
          href={~p"/"}
          class="group flex items-center gap-2.5"
          aria-label="Back to dashboard"
        >
          <.icon name="hero-fire" class="size-[18px] text-hd-orange" />
          <div class="flex items-baseline gap-2.5">
            <h1 class="text-base tracking-tight">Cleat</h1>
            <p class="hidden text-xs text-hd-muted sm:block">
              GitHub → SSH → your VPS
            </p>
          </div>
        </.link>

        <nav class="flex flex-wrap items-center gap-1 text-[13px]">
          <.theme_toggle id="theme-toggle" />
          <%= if @current_scope do %>
            <span class="hidden px-2 text-hd-muted sm:inline">
              {@current_scope.user.email}
            </span>
            <.link
              href={~p"/settings?tab=account"}
              class="rounded-lg px-2.5 py-1.5 text-hd-secondary transition-colors hover:bg-hd-raised hover:text-hd-text"
            >
              Account
            </.link>
            <.link
              href={~p"/users/log-out"}
              method="delete"
              class="rounded-lg px-2.5 py-1.5 text-hd-secondary transition-colors hover:bg-hd-raised hover:text-hd-text"
            >
              Log out
            </.link>
          <% else %>
            <.link
              href={~p"/users/log-in"}
              class="rounded-lg px-2.5 py-1.5 text-hd-secondary transition-colors hover:bg-hd-raised hover:text-hd-text"
            >
              Log in
            </.link>
            <.link
              :if={CleatDeploy.Accounts.registration_allowed?()}
              href={~p"/users/register"}
              class="paas-btn-primary"
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
        <div class="px-5 pt-6 pb-2">
          <p class="text-xs text-hd-muted">Navigate</p>
        </div>
        <nav class="flex min-h-0 flex-1 flex-col gap-0.5 overflow-y-auto px-3" aria-label="Main">
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
            label="Apps"
            count={@app_count}
          />
          <.nav_link
            id="nav-deployments"
            navigate={~p"/deployments"}
            active?={@active_tab == :deployments}
            icon="hero-rocket-launch"
            label="Deploys"
          />
          <.nav_link
            id="nav-signals"
            navigate={~p"/signals"}
            active?={@active_tab == :signals}
            icon="hero-heart"
            label="Saúde"
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
            <.icon name="hero-plus" class="size-3.5" /> New VM
          </.link>
          <.link navigate={~p"/apps/new"} class="paas-btn-primary w-full justify-center">
            <.icon name="hero-plus" class="size-3.5" /> Register App
          </.link>
        </div>
      </aside>

      <button
        id="sidebar-toggle"
        type="button"
        class="paas-shell-sidebar-toggle"
        aria-controls="app-sidebar"
        aria-expanded="true"
        aria-label="Hide sidebar"
        title="Hide sidebar"
        phx-hook="SidebarToggle"
        phx-update="ignore"
      >
        <span data-sidebar-icon="collapse">
          <.icon name="hero-chevron-left" class="size-3.5" />
        </span>
        <span data-sidebar-icon="expand">
          <.icon name="hero-chevron-right" class="size-3.5" />
        </span>
      </button>

      <div class="paas-shell-main flex flex-col">
        <div class="flex shrink-0 items-center justify-between gap-3 border-b border-hd-border bg-hd-bg px-3 py-2 lg:hidden">
          <nav
            id="app-nav-mobile"
            class="flex min-w-0 flex-1 items-center gap-0.5 overflow-x-auto rounded-lg border border-hd-border bg-hd-aside p-1"
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
              id="nav-deployments-mobile"
              navigate={~p"/deployments"}
              active?={@active_tab == :deployments}
              icon="hero-rocket-launch"
              label="Deploys"
              compact
            />
            <.nav_link
              id="nav-signals-mobile"
              navigate={~p"/signals"}
              active?={@active_tab == :signals}
              icon="hero-heart"
              label="Saúde"
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
          <div class="relative z-10 min-h-0 flex-1 overflow-y-auto overscroll-contain p-5 lg:p-8">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <footer
        id="app-footer"
        class="paas-shell-footer shrink-0 border-t border-hd-border bg-hd-aside px-4 py-2.5 select-none"
      >
        <div class="mx-auto flex max-w-7xl flex-col items-center justify-between gap-2 md:flex-row">
          <p class="font-mono text-[11px] text-hd-muted">
            Cleat <span class="text-hd-border">·</span> v0.1.0-alpha
          </p>
          <p class="font-mono text-[11px] text-hd-muted">
            self-hosted PaaS
          </p>
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
      class="flex size-8 items-center justify-center rounded-lg text-hd-muted transition-colors hover:bg-hd-raised hover:text-hd-text"
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
        "group flex items-center gap-2.5 rounded-lg text-[13px] font-medium transition-colors",
        @compact && "px-2.5 py-1.5",
        !@compact && "px-3 py-2",
        @active? && "bg-hd-raised text-hd-text ring-1 ring-hd-border ring-inset",
        !@active? && "text-hd-secondary hover:bg-hd-card/60 hover:text-hd-text"
      ]}
    >
      <.icon
        name={@icon}
        class={["size-4 shrink-0", @active? && "text-hd-orange", !@active? && "text-hd-muted"]}
      />
      <span class="min-w-0 truncate">{@label}</span>
      <span :if={@count != nil} class="ml-auto font-mono text-xs tabular-nums text-hd-muted">
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
      class="pointer-events-none fixed top-16 left-1/2 z-50 -translate-x-1/2"
    >
      <div
        :if={msg = Phoenix.Flash.get(@flash, :info)}
        class="mt-2 flex items-center gap-2.5 rounded-lg border border-hd-border bg-hd-raised px-3.5 py-2 text-[13px] text-hd-text shadow-lg"
      >
        <span class="size-1.5 rounded-full bg-hd-green" />
        {msg}
      </div>
      <div
        :if={msg = Phoenix.Flash.get(@flash, :error)}
        class="mt-2 flex items-center gap-2.5 rounded-lg border border-hd-border bg-hd-raised px-3.5 py-2 text-[13px] text-hd-text shadow-lg"
      >
        <span class="size-1.5 rounded-full bg-hd-red" />
        {msg}
      </div>
    </div>
    """
  end
end
