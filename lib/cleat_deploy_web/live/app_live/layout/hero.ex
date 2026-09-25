defmodule CleatDeployWeb.AppLive.Layout.Hero do
  @moduledoc false
  use CleatDeployWeb, :html

  alias CleatDeployWeb.AppLive.Layout.{Header, HeroModals}

  def shell_hero(assigns) do
    assigns =
      assigns
      |> assign(
        runtime_badge: Header.runtime_badge_label(assigns.app.runtime),
        runtime_badge_class: Header.runtime_badge_class(assigns.app.runtime)
      )
      |> assign(
        can_hibernate?: assigns.app.runtime != "static",
        static?: assigns.app.runtime == "static",
        indexable?: assigns.app.indexable == true,
        hibernated?: Header.hibernated?(assigns.memory),
        idle_on?: assigns.app.idle_shutdown_enabled,
        idle_hint: HeroModals.idle_hint(assigns),
        idle_confirm_hint: HeroModals.idle_confirm_hint(assigns),
        idle_window: HeroModals.idle_window(assigns),
        unit_label: CleatDeploy.Apps.App.unit_name(assigns.app),
        wake_hint: CleatDeploy.Apps.RuntimeControl.wake_hint(assigns.app)
      )

    ~H"""
    <div id="app-hero" class="paas-card space-y-3 p-4">
      <div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
        <div class="flex items-center gap-2">
          <span
            id="app-runtime-badge"
            class={[
              "inline-flex h-7 w-12 items-center justify-center rounded border font-mono text-[10px] font-bold",
              @runtime_badge_class
            ]}
          >
            {@runtime_badge}
          </span>
          <div>
            <h2 class="font-display text-base font-semibold text-hd-text">{@app.name}</h2>
            <p class="flex items-center gap-1 font-mono text-[11px] text-hd-muted">
              <.icon name="hero-code-bracket" class="size-3" />
              <Header.repo_link id="app-repo-hero" repo={@app.github_repo} class="hover:text-hd-text" />
              <span class="text-hd-border">|</span> branch: {@app.branch}
            </p>
          </div>
        </div>

        <.link
          :if={@app.host not in [nil, ""]}
          id="app-host-hero"
          href={"https://#{@app.host}"}
          target="_blank"
          rel="noopener noreferrer"
          class="inline-flex items-center gap-1.5 font-mono text-sm text-hd-orange transition-colors hover:text-hd-orange-dark hover:underline md:mx-auto"
        >
          <.icon name="hero-globe-alt" class="size-3.5" />
          {@app.host}
          <.icon name="hero-arrow-top-right-on-square" class="size-3" />
        </.link>

        <div class="flex flex-wrap items-center gap-2">
          <button
            :if={@can_hibernate?}
            id="hibernate-button"
            type="button"
            phx-click={if @hibernated?, do: "wake_app", else: "open_hibernate"}
            disabled={@deploying?}
            phx-disable-with={@hibernated? && "Waking…"}
            class={["paas-btn-secondary uppercase", @deploying? && "opacity-50"]}
            title="Stops the process (no CPU/RAM); release and data stay on disk"
          >
            <.icon name={if @hibernated?, do: "hero-bolt", else: "hero-moon"} class="size-3.5" />
            {if @hibernated?, do: "Wake up", else: "Hibernate"}
          </button>
          <button
            :if={@can_hibernate?}
            id="app-idle-toggle"
            type="button"
            phx-click="open_idle_sleep"
            data-state={if @idle_on?, do: "on", else: "off"}
            title={@idle_hint}
            class={[
              "inline-flex items-center gap-1 rounded-md border px-2.5 py-1 font-mono text-[10px] font-semibold tracking-wide uppercase transition-colors",
              @idle_on? && "border-hd-green/50 bg-hd-green/10 text-hd-green",
              !@idle_on? &&
                "border-hd-border bg-hd-card text-hd-muted hover:border-hd-orange/40 hover:text-hd-text"
            ]}
          >
            <.icon name="hero-moon" class="size-3" /> auto sleep {if @idle_on?, do: "on", else: "off"}
          </button>
          <button
            :if={@static?}
            id="app-indexable-toggle"
            type="button"
            phx-click="toggle_indexable"
            data-state={if @indexable?, do: "on", else: "off"}
            title="Google indexing. Takes effect on the next deploy."
            class={[
              "inline-flex items-center gap-1 rounded-md border px-2.5 py-1 font-mono text-[10px] font-semibold tracking-wide uppercase transition-colors",
              @indexable? && "border-hd-green/50 bg-hd-green/10 text-hd-green",
              !@indexable? &&
                "border-hd-border bg-hd-card text-hd-muted hover:border-hd-orange/40 hover:text-hd-text"
            ]}
          >
            <.icon name="hero-magnifying-glass" class="size-3" />
            indexing {if @indexable?, do: "on", else: "off"}
          </button>
          <button
            :if={@app.github_repo not in [nil, ""]}
            id="new-instance-button"
            type="button"
            phx-click="open_new_instance"
            class="paas-btn-secondary uppercase"
            title="Register another instance of this repository on a different branch"
          >
            <.icon name="hero-square-2-stack" class="size-3.5" /> New instance
          </button>
          <button
            id="deploy-button"
            type="button"
            phx-click="deploy"
            disabled={@deploying?}
            class={["paas-btn-primary uppercase", @deploying? && "opacity-50"]}
          >
            <.icon
              name={if @deploying?, do: "hero-arrow-path", else: "hero-play"}
              class={["size-3.5", @deploying? && "motion-safe:animate-spin"]}
            />
            {if @deploying?, do: "Build in progress…", else: "Deploy now"}
          </button>
          <button
            :if={@deploying?}
            id="cancel-deploy-button"
            type="button"
            phx-click="open_cancel_deploy"
            class="paas-btn-secondary uppercase"
          >
            <.icon name="hero-x-mark" class="size-3.5 text-rose-400" /> Cancel deploy
          </button>
        </div>
      </div>

      <p :if={not @global_enabled?} id="app-sleep-global-off" class="text-[11px] text-hd-orange">
        Platform auto sleep is disabled —
        <.link navigate={~p"/settings"} class="underline">open Settings</.link>
        — the per-app flag only hibernates once the platform switch is on.
      </p>

      <HeroModals.modals {assigns} />
    </div>
    """
  end
end
