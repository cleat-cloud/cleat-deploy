defmodule CleatDeployWeb.AppLive.Layout do
  @moduledoc false
  use CleatDeployWeb, :html

  import CleatDeployWeb.CoreComponents, only: [icon: 1]

  attr :app, :map, required: true
  attr :apps, :list, required: true

  def shell_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-3 border-b border-hd-border/40 pb-3">
      <div class="flex items-center gap-2">
        <span class="font-mono text-[10px] uppercase tracking-wider text-hd-muted">
          Active Application:
        </span>
        <select
          id="app-selector"
          class="paas-select"
          phx-change="select_app"
          name="app_id"
        >
          <option :for={app <- @apps} value={app.id} selected={app.id == @app.id}>
            {app.name} ({app.branch})
          </option>
        </select>
      </div>
      <div class="text-xs text-hd-muted">
        Repository mapping:
        <.repo_link
          id="app-repo-mapping"
          repo={@app.github_repo}
          class="font-mono text-hd-orange hover:text-hd-orange-dark"
        />
      </div>
    </div>
    """
  end

  attr :app, :map, required: true
  attr :deploying?, :boolean, required: true
  attr :confirming_cancel?, :boolean, default: false
  attr :confirming_hibernate?, :boolean, default: false
  attr :confirming_idle_sleep?, :boolean, default: false
  attr :global_enabled?, :boolean, default: false
  attr :minutes, :integer, default: nil
  attr :memory, :any, default: nil

  def shell_hero(assigns) do
    assigns =
      assigns
      |> assign(
        runtime_badge: runtime_badge_label(assigns.app.runtime),
        runtime_badge_class: runtime_badge_class(assigns.app.runtime)
      )
      |> assign(
        can_hibernate?: assigns.app.runtime != "static",
        hibernated?: hibernated?(assigns.memory),
        idle_on?: assigns.app.idle_shutdown_enabled,
        idle_hint: idle_hint(assigns),
        idle_confirm_hint: idle_confirm_hint(assigns),
        idle_window: idle_window(assigns),
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
              <.repo_link id="app-repo-hero" repo={@app.github_repo} class="hover:text-hd-text" />
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

        <div
          :if={@confirming_cancel? and @deploying?}
          id="cancel-deploy-modal"
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          phx-window-keydown="close_cancel_deploy"
          phx-key="Escape"
          role="presentation"
        >
          <button
            type="button"
            class="paas-modal-backdrop absolute inset-0 bg-black/70 backdrop-blur-sm"
            phx-click="close_cancel_deploy"
            aria-label="Close confirmation"
          />
          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="cancel-deploy-title"
            class="paas-modal-panel relative w-full max-w-md overflow-hidden rounded-xl border border-hd-border bg-hd-card shadow-[0_24px_80px_rgba(0,0,0,0.55)]"
          >
            <div class="h-px bg-gradient-to-r from-transparent via-rose-500/70 to-transparent" />
            <div class="space-y-5 p-5 sm:p-6">
              <div class="flex items-start gap-3">
                <div class="flex size-11 shrink-0 items-center justify-center rounded-full border border-rose-500/30 bg-rose-500/10 text-rose-400">
                  <.icon name="hero-exclamation-triangle" class="size-5" />
                </div>
                <div class="min-w-0 space-y-1">
                  <h3
                    id="cancel-deploy-title"
                    class="font-display text-base font-semibold text-hd-text"
                  >
                    Cancel this deploy?
                  </h3>
                  <p class="text-[13px] leading-relaxed text-hd-muted">
                    The pending job is dropped and the deployment is marked failed. A build already
                    running on {@app.server.name} is not interrupted.
                  </p>
                </div>
              </div>

              <div class="rounded-lg border border-hd-border bg-hd-aside px-3 py-3">
                <p class="font-display text-sm font-semibold text-hd-text">{@app.name}</p>
                <p class="mt-1 font-mono text-[11px] text-hd-muted">
                  {@app.github_repo} · branch {@app.branch}
                </p>
              </div>

              <div class="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
                <button
                  id="keep-deploy-button"
                  type="button"
                  phx-click="close_cancel_deploy"
                  class="paas-btn-secondary justify-center"
                >
                  Keep it
                </button>
                <button
                  id="confirm-cancel-deploy-button"
                  type="button"
                  phx-click="cancel_deploy"
                  phx-disable-with="Cancelling…"
                  class="inline-flex items-center justify-center gap-1.5 rounded-md bg-rose-500 px-3 py-1.5 text-xs font-bold text-white transition-colors hover:bg-rose-400"
                >
                  <.icon name="hero-x-mark" class="size-3.5" /> Yes, cancel it
                </button>
              </div>
            </div>
          </div>
        </div>

        <div
          :if={@confirming_hibernate?}
          id="hibernate-modal"
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          phx-window-keydown="close_hibernate"
          phx-key="Escape"
          role="presentation"
        >
          <button
            type="button"
            class="paas-modal-backdrop absolute inset-0 bg-black/70 backdrop-blur-sm"
            phx-click="close_hibernate"
            aria-label="Close confirmation"
          />
          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="hibernate-title"
            class="paas-modal-panel relative w-full max-w-md overflow-hidden rounded-xl border border-hd-border bg-hd-card shadow-[0_24px_80px_rgba(0,0,0,0.55)]"
          >
            <div class="h-px bg-gradient-to-r from-transparent via-hd-blue/70 to-transparent" />
            <div class="space-y-5 p-5 sm:p-6">
              <div class="flex items-start gap-3">
                <div class="flex size-11 shrink-0 items-center justify-center rounded-full border border-hd-blue/30 bg-hd-blue/10 text-hd-blue">
                  <.icon name="hero-moon" class="size-5" />
                </div>
                <div class="min-w-0 space-y-1">
                  <h3 id="hibernate-title" class="font-display text-base font-semibold text-hd-text">
                    Hibernate {@app.name}?
                  </h3>
                  <p class="text-[13px] leading-relaxed text-hd-muted">
                    The process is stopped, so it stops using CPU and RAM. The release, the data
                    directory and the Caddy site stay on disk — nothing is rebuilt to bring it back. {@wake_hint}
                  </p>
                </div>
              </div>

              <div class="rounded-lg border border-hd-border bg-hd-aside px-3 py-3">
                <p class="font-display text-sm font-semibold text-hd-text">{@app.name}</p>
                <p class="mt-1 font-mono text-[11px] text-hd-muted">
                  {@app.host} · unit {@unit_label}
                </p>
              </div>

              <div class="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
                <button
                  id="keep-hibernate-button"
                  type="button"
                  phx-click="close_hibernate"
                  class="paas-btn-secondary justify-center"
                >
                  Keep it running
                </button>
                <button
                  id="confirm-hibernate-button"
                  type="button"
                  phx-click="hibernate_app"
                  phx-disable-with="Hibernating…"
                  class="paas-btn-primary justify-center"
                >
                  <.icon name="hero-moon" class="size-3.5" /> Yes, hibernate
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div
        :if={@confirming_idle_sleep?}
        id="idle-sleep-modal"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        phx-window-keydown="close_idle_sleep"
        phx-key="Escape"
        role="presentation"
      >
        <button
          type="button"
          class="paas-modal-backdrop absolute inset-0 bg-black/70 backdrop-blur-sm"
          phx-click="close_idle_sleep"
          aria-label="Close confirmation"
        />
        <div
          role="dialog"
          aria-modal="true"
          aria-labelledby="idle-sleep-title"
          class="paas-modal-panel relative w-full max-w-md overflow-hidden rounded-xl border border-hd-border bg-hd-card shadow-[0_24px_80px_rgba(0,0,0,0.55)]"
        >
          <div class="h-px bg-gradient-to-r from-transparent via-hd-green/70 to-transparent" />
          <div class="space-y-5 p-5 sm:p-6">
            <div class="flex items-start gap-3">
              <div class="flex size-11 shrink-0 items-center justify-center rounded-full border border-hd-green/30 bg-hd-green/10 text-hd-green">
                <.icon name="hero-moon" class="size-5" />
              </div>
              <div class="min-w-0 space-y-1">
                <h3 id="idle-sleep-title" class="font-display text-base font-semibold text-hd-text">
                  {if @idle_on?, do: "Turn off auto sleep?", else: "Turn on auto sleep?"}
                </h3>
                <p class="text-[13px] leading-relaxed text-hd-muted">{@idle_confirm_hint}</p>
              </div>
            </div>

            <div class="rounded-lg border border-hd-border bg-hd-aside px-3 py-3">
              <p class="font-display text-sm font-semibold text-hd-text">{@app.name}</p>
              <p class="mt-1 font-mono text-[11px] text-hd-muted">
                {@app.host} · idle window {@idle_window}
              </p>
            </div>

            <div class="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
              <button
                id="keep-idle-sleep-button"
                type="button"
                phx-click="close_idle_sleep"
                class="paas-btn-secondary justify-center"
              >
                Keep it as is
              </button>
              <button
                id="confirm-idle-sleep-button"
                type="button"
                phx-click="toggle_idle_shutdown"
                phx-disable-with="Saving…"
                class="paas-btn-primary justify-center"
              >
                {if @idle_on?, do: "Yes, turn it off", else: "Yes, turn it on"}
              </button>
            </div>
          </div>
        </div>
      </div>

      <p :if={not @global_enabled?} id="app-sleep-global-off" class="text-[11px] text-hd-orange">
        Platform auto sleep is disabled —
        <.link navigate={~p"/settings"} class="underline">open Settings</.link>
        — the per-app flag only hibernates once the platform switch is on.
      </p>
    </div>
    """
  end

  attr :app, :map, required: true
  attr :memory, :any, default: nil

  def shell_info_tiles(assigns) do
    peak = CleatDeploy.Apps.RuntimeMemory.format_peak(assigns.memory)

    assigns =
      assign(assigns,
        ram_label: CleatDeploy.Apps.RuntimeMemory.format(assigns.memory),
        ram_sub: peak || "systemd cgroup",
        cpu_label: CleatDeploy.Apps.RuntimeMemory.format_cpu(assigns.memory),
        disk_label: CleatDeploy.Apps.RuntimeMemory.format_disk(assigns.memory),
        status_label: CleatDeploy.Apps.RuntimeMemory.format_status(assigns.memory)
      )

    ~H"""
    <div class="space-y-3">
      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <.info_tile label="Domain Host" value={@app.host} mono sub="IPv4 ingress endpoint" />
        <.info_tile
          id="app-deploy-branch-tile"
          label="Deploy Branch"
          value={@app.branch}
          mono
          sub="Edit auto-deploy target"
          href={~p"/apps/#{@app.id}?tab=webhook"}
        />
        <.info_tile label="Target Server" value={@app.server.host_ip} mono sub={@app.server.name} />
        <.info_tile
          label="Auto Deploy"
          value={if @app.auto_deploy, do: "Webhook Enabled", else: "Manual Selector"}
          sub="HMAC Sha256 keys"
        />
      </div>
      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <.info_tile id="app-memory-tile" label="Memory" value={@ram_label} mono sub={@ram_sub} />
        <.info_tile id="app-cpu-tile" label="CPU" value={@cpu_label} mono sub="Share of one vCPU" />
        <.info_tile id="app-disk-tile" label="Disk" value={@disk_label} mono sub="Release + data" />
        <.info_tile
          id="app-status-tile"
          label="Status"
          value={@status_label}
          mono
          sub="systemd unit"
        />
      </div>
    </div>
    """
  end

  # Addons the deploy recorded for this app, with the live status of each
  # datastore on the server (`:status` is nil while the probe runs).
  attr :app, :map, required: true
  attr :addons, :list, required: true
  attr :status, :any, default: nil

  def addons_card(assigns) do
    ~H"""
    <div id="app-addons" class="paas-card overflow-hidden">
      <div class="flex items-start gap-3 border-b border-hd-border bg-hd-aside/60 px-4 py-3">
        <div class="flex size-9 shrink-0 items-center justify-center rounded-md border border-hd-border bg-hd-card">
          <.icon name="hero-circle-stack" class="size-4 text-hd-orange" />
        </div>
        <div class="min-w-0 space-y-0.5">
          <h3 class="font-display text-sm font-semibold text-hd-text">Managed addons</h3>
          <p class="text-xs leading-relaxed text-hd-muted">
            Declared in <span class="font-mono text-hd-text">.cleat_deploy/deploy.json</span>
            — the connection strings live in this app's env vars.
          </p>
        </div>
        <button
          id="refresh-addons"
          type="button"
          phx-click="refresh_addon_status"
          phx-disable-with="Checking…"
          class="paas-btn-secondary ml-auto shrink-0 text-[10px]"
        >
          <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
        </button>
      </div>

      <ul>
        <li
          :for={addon <- @addons}
          id={"addon-#{addon_id(addon)}"}
          class="flex flex-wrap items-center justify-between gap-3 border-b border-hd-border/50 px-4 py-3 last:border-b-0"
        >
          <div class="flex items-center gap-2.5">
            <span class={[
              "size-2 shrink-0 rounded-full",
              dot_class(addon_state(@status, addon))
            ]} />
            <div class="min-w-0 space-y-0.5">
              <p class="font-mono text-[12px] text-hd-text">{addon}</p>
              <p class="text-[11px] text-hd-muted">{addon_detail(@status, addon)}</p>
            </div>
          </div>

          <button
            type="button"
            id={"rotate-#{addon_id(addon)}"}
            phx-click="rotate_addon_prompt"
            phx-value-addon={addon}
            class="paas-btn-secondary text-[10px] uppercase"
          >
            <.icon name="hero-arrow-path" class="size-3" /> Rotate credentials
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :addon, :string, required: true

  def rotate_addon_modal(assigns) do
    ~H"""
    <div
      id="rotate-addon-modal"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      phx-window-keydown="close_rotate_addon"
      phx-key="Escape"
      role="presentation"
    >
      <button
        type="button"
        class="paas-modal-backdrop absolute inset-0 bg-black/70 backdrop-blur-sm"
        phx-click="close_rotate_addon"
        aria-label="Close confirmation"
      />
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="rotate-addon-title"
        class="paas-modal-panel relative w-full max-w-md overflow-hidden rounded-xl border border-hd-border bg-hd-card shadow-[0_24px_80px_rgba(0,0,0,0.55)]"
      >
        <div class="h-px bg-gradient-to-r from-transparent via-hd-orange/70 to-transparent" />
        <div class="space-y-5 p-5 sm:p-6">
          <div class="flex items-start gap-3">
            <div class="flex size-11 shrink-0 items-center justify-center rounded-full border border-hd-orange/30 bg-hd-orange/10 text-hd-orange">
              <.icon name="hero-arrow-path" class="size-5" />
            </div>
            <div class="min-w-0 space-y-1">
              <h3 id="rotate-addon-title" class="font-display text-base font-semibold text-hd-text">
                Rotate {addon_label(@addon)} credentials?
              </h3>
              <p class="text-[13px] leading-relaxed text-hd-muted">
                A new password is generated and stored in this app's env var right away. The server
                only picks it up on the next deploy — until then the app keeps using the current
                credentials, which stay valid.
              </p>
            </div>
          </div>

          <div class="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
            <button
              id="keep-addon-credentials-button"
              type="button"
              phx-click="close_rotate_addon"
              class="paas-btn-secondary justify-center"
            >
              Keep current credentials
            </button>
            <button
              id="confirm-rotate-addon-button"
              type="button"
              phx-click="rotate_addon"
              phx-value-addon={@addon}
              phx-disable-with="Rotating…"
              class="paas-btn-primary justify-center"
            >
              <.icon name="hero-arrow-path" class="size-3.5" /> Yes, rotate
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp addon_label("postgres:pgvector"), do: "Postgres"
  defp addon_label("redis"), do: "Redis"
  defp addon_label(addon), do: addon

  # `postgres:pgvector` is not usable in a CSS selector.
  defp addon_id(addon), do: String.replace(addon, ":", "-")

  defp addon_state(nil, _addon), do: :unknown

  defp addon_state(%{error: _message}, _addon), do: :error

  defp addon_state(status, addon) when is_map(status) do
    case Map.get(status, addon) do
      %{state: "ready"} -> :ready
      %{state: _other} -> :down
      nil -> :unknown
    end
  end

  defp addon_detail(nil, _addon), do: "Checking the server…"
  defp addon_detail(%{error: message}, _addon), do: "Could not check: #{message}"

  defp addon_detail(status, addon) when is_map(status) do
    case Map.get(status, addon) do
      %{state: "ready", detail: detail} -> "Running · #{detail}"
      %{state: state, detail: detail} -> "#{state} · #{detail}"
      nil -> "Not installed yet — deploy this app"
    end
  end

  defp dot_class(:ready), do: "bg-hd-green"
  defp dot_class(:down), do: "bg-hd-muted"
  defp dot_class(:error), do: "bg-rose-400"
  defp dot_class(_state), do: "bg-hd-muted/40"

  attr :app, :map, required: true
  attr :active_tab, :atom, required: true
  attr :detail_tabs, :list, required: true

  def tab_bar(assigns) do
    ~H"""
    <div
      role="tablist"
      aria-label="App configuration"
      class="flex flex-wrap items-center gap-1 border-b border-hd-border bg-hd-aside p-1"
    >
      <.detail_tab_link
        tab={:deployments}
        label="Deployments"
        icon="hero-rocket-launch"
        active?={@active_tab == :deployments}
        href={~p"/apps/#{@app.id}/deployments"}
      />
      <.detail_tab_link
        tab={:logs}
        label="Logs"
        icon="hero-command-line"
        active?={@active_tab == :logs}
        href={~p"/apps/#{@app.id}?tab=logs"}
      />
      <.detail_tab_link
        :if={:domains in @detail_tabs}
        tab={:domains}
        label="Tenant domains"
        icon="hero-globe-alt"
        active?={@active_tab == :domains}
        href={~p"/apps/#{@app.id}?tab=domains"}
      />
      <.detail_tab_link
        tab={:environment}
        label="Environment"
        icon="hero-circle-stack"
        active?={@active_tab == :environment}
        href={~p"/apps/#{@app.id}?tab=environment"}
      />
      <.detail_tab_link
        :if={:runtime in @detail_tabs}
        tab={:runtime}
        label="Runtime"
        icon="hero-cube"
        active?={@active_tab == :runtime}
        href={~p"/apps/#{@app.id}?tab=runtime"}
      />
      <.detail_tab_link
        tab={:webhook}
        label="Webhook"
        icon="hero-link"
        active?={@active_tab == :webhook}
        href={~p"/apps/#{@app.id}?tab=webhook"}
      />
      <.detail_tab_link
        tab={:danger}
        label="Danger zone"
        icon="hero-exclamation-triangle"
        tone={:danger}
        active?={@active_tab == :danger}
        href={~p"/apps/#{@app.id}?tab=danger"}
      />
    </div>
    """
  end

  attr :tab, :atom, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :active?, :boolean, required: true
  attr :href, :string, required: true
  attr :tone, :atom, default: :default

  defp detail_tab_link(assigns) do
    ~H"""
    <.link
      id={"app-detail-tab-#{@tab}"}
      navigate={@href}
      role="tab"
      aria-selected={@active?}
      class={[
        "flex items-center gap-1.5 rounded-md px-3 py-1.5 text-xs font-semibold tracking-wide transition-all",
        @active? && @tone == :danger && "border border-rose-500/40 bg-hd-card text-rose-400",
        @active? && @tone != :danger && "border border-hd-border bg-hd-card text-hd-orange",
        !@active? && @tone == :danger && "text-hd-muted hover:text-rose-400",
        !@active? && @tone != :danger && "text-hd-muted hover:text-hd-text"
      ]}
    >
      <.icon name={@icon} class="size-3.5" />
      <span>{@label}</span>
    </.link>
    """
  end

  def detail_tabs(custom_domain_app?, runtime_packages) do
    [:deployments, :logs]
    |> then(fn tabs -> if custom_domain_app?, do: tabs ++ [:domains], else: tabs end)
    |> Kernel.++([:environment])
    |> then(fn tabs -> if runtime_packages != [], do: tabs ++ [:runtime], else: tabs end)
    |> Kernel.++([:webhook, :danger])
  end

  def parse_detail_tab(tab)
      when tab in ["logs", "domains", "environment", "runtime", "webhook", "danger"] do
    String.to_existing_atom(tab)
  end

  def parse_detail_tab(_), do: :environment

  # Live systemd state read by RuntimeMemory; unknown (nil) keeps the "Hibernate"
  # affordance, which is a no-op on an app that is already stopped.
  defp hibernated?(%{active?: false}), do: true
  defp hibernated?(_memory), do: false

  # Tooltip for the auto sleep chip in the hero: state, window and the two
  # caveats (needs a deploy; the platform switch can be off).
  defp idle_hint(assigns) do
    state =
      if assigns.app.idle_shutdown_enabled,
        do: "Auto sleep is on for this app.",
        else: "Auto sleep is off for this app."

    [
      state,
      "The process is stopped after #{idle_window(assigns)} without a request and the next request starts it again.",
      "Takes effect after the next deploy of this app.",
      if(assigns[:global_enabled?],
        do: nil,
        else: "Platform auto sleep is currently disabled in Settings."
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  # Confirmation copy, which reads differently depending on the direction of the
  # toggle: arming can take the app down on its own, disarming only stops the
  # sweeper from looking at it.
  defp idle_confirm_hint(assigns) do
    if assigns.app.idle_shutdown_enabled do
      "The idle sweeper stops looking at this app, and the next deploy removes the wake wiring " <>
        "(forward_auth + stamp) from the server. Nothing is stopped by this change alone."
    else
      [
        "Once this app is deployed with the flag on, the process is stopped after",
        idle_window(assigns),
        "without a request, and the next request starts it again.",
        if(assigns[:global_enabled?],
          do: nil,
          else: "Platform auto sleep is off in Settings, so nothing happens until it is on."
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
    end
  end

  defp idle_window(assigns) do
    case assigns[:minutes] do
      minutes when is_integer(minutes) -> "#{minutes} min"
      _ -> "the platform window"
    end
  end

  defp runtime_badge_label("golang"), do: "GO"
  defp runtime_badge_label("node"), do: "JS"
  defp runtime_badge_label("rails"), do: "RB"
  defp runtime_badge_label("static"), do: "HTML"
  defp runtime_badge_label(_runtime), do: "PHX"

  defp runtime_badge_class("golang"), do: "border-hd-green/40 bg-hd-green/10 text-hd-green"
  defp runtime_badge_class("node"), do: "border-hd-blue/40 bg-hd-blue/10 text-hd-blue"
  defp runtime_badge_class("rails"), do: "border-hd-red/40 bg-hd-red/10 text-hd-red"
  defp runtime_badge_class(_runtime), do: "border-hd-border bg-hd-aside text-hd-orange"

  attr :id, :string, required: true
  attr :repo, :string, required: true
  attr :class, :string, required: true

  defp repo_link(assigns) do
    ~H"""
    <.link
      id={@id}
      href={"https://github.com/#{@repo}"}
      target="_blank"
      rel="noopener noreferrer"
      class={[@class, "transition-colors hover:underline"]}
    >
      {@repo}
    </.link>
    """
  end
end
