defmodule CleatDeployWeb.Layouts do
  @moduledoc """
  Layouts for Cleat control panel.
  """
  use CleatDeployWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :active_tab, :atom, default: :dashboard
  attr :server_count, :integer, default: 0
  attr :app_count, :integer, default: 0
  attr :current_scope, :map, default: nil

  slot :inner_block, required: true

  def app(assigns) do
    cond do
      assigns.active_tab == :auth ->
        ~H"""
        <div class="relative flex min-h-screen flex-col items-center justify-center bg-hd-bg px-4 py-12 text-hd-text antialiased">
          <div class="absolute top-4 right-4">
            <PaasShell.theme_toggle id="theme-toggle-auth" />
          </div>
          <div class="mb-8 flex items-center gap-2.5">
            <div class="flex size-9 items-center justify-center rounded-lg border border-hd-border bg-hd-card">
              <.icon name="hero-fire" class="size-5 text-hd-orange" />
            </div>
            <h1 class="font-display text-lg font-semibold tracking-tight">Cleat</h1>
          </div>

          <div class="w-full max-w-sm space-y-4">
            <.flash kind={:info} flash={@flash} />
            <.flash kind={:error} flash={@flash} />
            {render_slot(@inner_block)}
          </div>
        </div>
        """

      assigns.active_tab == :landing ->
        ~H"""
        <div class="flex min-h-screen flex-col bg-hd-bg text-hd-text antialiased">
          <header class="border-b border-hd-border bg-hd-aside px-4 py-3">
            <div class="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-3">
              <.link navigate={~p"/"} class="group flex items-center gap-2.5" aria-label="Cleat">
                <div class="flex size-9 items-center justify-center rounded-lg border border-hd-border bg-hd-card">
                  <.icon name="hero-fire" class="size-5 text-hd-orange" />
                </div>
                <div>
                  <div class="flex items-center gap-1.5">
                    <h1 class="font-display text-lg font-semibold tracking-tight">Cleat</h1>
                    <span class="rounded-full border border-hd-border bg-hd-card px-2 py-0.5 font-mono text-[10px] tracking-widest text-hd-muted uppercase">
                      MVP
                    </span>
                  </div>
                  <p class="hidden text-xs text-hd-muted sm:block">GitHub → SSH → your VPS</p>
                </div>
              </.link>

              <div class="flex items-center gap-2 text-xs font-medium">
                <PaasShell.theme_toggle id="theme-toggle-landing" />
                <span :if={@current_scope} class="hidden text-hd-muted sm:inline">
                  {@current_scope.user.email}
                </span>
                <.link
                  :if={@current_scope}
                  navigate={~p"/"}
                  class="paas-btn-primary px-3 py-1.5"
                >
                  Open panel
                </.link>
                <.link
                  :if={is_nil(@current_scope)}
                  href={~p"/users/log-in"}
                  class="paas-btn-secondary px-3 py-1.5"
                >
                  Log in
                </.link>
                <.link
                  :if={is_nil(@current_scope)}
                  href={~p"/users/register"}
                  class="paas-btn-primary px-3 py-1.5"
                >
                  Register
                </.link>
              </div>
            </div>
          </header>

          <main class="mx-auto w-full max-w-5xl flex-1 px-4 py-8">
            <.flash kind={:info} flash={@flash} />
            <.flash kind={:error} flash={@flash} />
            {render_slot(@inner_block)}
          </main>

          <footer class="border-t border-hd-border bg-hd-aside px-4 py-4">
            <p class="text-center font-mono text-[10px] tracking-wider text-hd-muted">
              CLEAT · SELF-HOSTED PAAS PANEL
            </p>
          </footer>
        </div>
        """

      true ->
        ~H"""
        <PaasShell.shell
          flash={@flash}
          active_tab={@active_tab}
          server_count={@server_count}
          app_count={@app_count}
          current_scope={@current_scope}
        >
          {render_slot(@inner_block)}
        </PaasShell.shell>
        """
    end
  end
end
