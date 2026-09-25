defmodule CleatDeployWeb.AppLive.Show.Tabs do
  @moduledoc false
  use CleatDeployWeb, :html

  alias CleatDeploy.Apps.RuntimeLogs
  alias CleatDeployWeb.AppLive.Show.{EnvTab, Runtime}

  def panel(assigns) do
    ~H"""
    <div :if={@app_detail_tab == :domains} id="custom-domain-checklist" class="space-y-3">
      <div class="flex flex-wrap items-center gap-2">
        <h3 class="font-display text-xs font-semibold text-hd-text">Custom tenant domains</h3>
        <span class="rounded border border-hd-orange/40 bg-hd-orange/10 px-2 py-0.5 font-mono text-[9px] text-hd-orange">
          Solo server · on-demand TLS
        </span>
      </div>
      <p class="text-[11px] leading-relaxed text-hd-muted">
        Tenants point a <span class="font-mono text-hd-text">CNAME</span>
        to <span class="font-mono text-hd-orange">DOMAIN_CNAME_TARGET</span>
        (set to {@app.host}), then verify DNS in the admin panel.
        Caddy issues certificates only after the tenant domain is verified.
      </p>
      <ul class="space-y-1 font-mono text-[10px] text-hd-muted">
        <li>
          <span class="text-hd-orange">PLATFORM_HOSTS</span> — platform hostnames served directly
        </li>
        <li>
          <span class="text-hd-orange">DOMAIN_CNAME_TARGET</span>
          — CNAME anchor for tenant custom domains
        </li>
        <li>
          <span class="text-hd-orange">PHX_HOST</span> — primary platform host ({@app.host})
        </li>
      </ul>
    </div>

    <div :if={@app_detail_tab == :logs} id="app-runtime-logs" class="space-y-3">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="space-y-0.5">
          <h3 class="font-display text-xs font-semibold text-hd-text">
            Runtime logs
          </h3>
          <p class="text-[11px] text-hd-muted">
            Last {RuntimeLogs.line_count()} journal lines from
            <span class="font-mono text-hd-orange">
              {Runtime.log_unit(@app, @runtime_logs)}
            </span>
            on {@app.server.name}.
          </p>
        </div>
        <button
          id="refresh-app-logs"
          type="button"
          phx-click="refresh_logs"
          phx-disable-with="Reading…"
          class="paas-btn-secondary text-[10px]"
        >
          <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
        </button>
      </div>

      <div
        :if={@logs_error}
        class="rounded border border-rose-500/40 bg-rose-500/10 px-3 py-2 font-mono text-[11px] text-rose-400"
      >
        {@logs_error}
      </div>

      <div class="overflow-hidden rounded-md border border-hd-border bg-hd-bg font-mono text-[11px] text-hd-text">
        <div class="flex items-center justify-between border-b border-hd-border bg-hd-aside px-3 py-1.5">
          <div class="flex items-center gap-1.5">
            <.icon name="hero-command-line" class="size-3.5 text-hd-orange" />
            <span class="text-[10px] font-semibold tracking-wider text-hd-muted">
              SYSTEMD JOURNAL
            </span>
          </div>
          <span :if={@runtime_logs} class="font-mono text-[10px] text-hd-muted">
            {Calendar.strftime(@runtime_logs.fetched_at, "%Y-%m-%d %H:%M:%S UTC")}
          </span>
        </div>
        <div
          id="app-runtime-logs-body"
          phx-hook=".LogsScroll"
          class="h-96 overflow-auto p-3 font-mono text-[11px] leading-5"
        >
          <div
            :if={is_nil(@runtime_logs) and is_nil(@logs_error)}
            class="text-hd-muted"
          >
            Reading journal…
          </div>
          <div
            :if={@runtime_logs && @runtime_logs.lines == []}
            class="text-hd-muted"
          >
            No journal entries for this unit yet.
          </div>
          <div
            :for={{line, index} <- Runtime.log_lines(@runtime_logs)}
            id={"log-line-#{index + 1}"}
            class="flex items-start"
          >
            <span class="sticky left-0 z-10 mr-3 w-8 shrink-0 select-none bg-hd-bg pr-1 text-right tabular-nums text-hd-muted/40">
              {index + 1}
            </span>
            <span class={["min-w-0 whitespace-pre", Runtime.log_line_class(line)]}>{line}</span>
          </div>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".LogsScroll">
            export default {
              mounted() { this.el.scrollTop = this.el.scrollHeight },
              updated() { this.el.scrollTop = this.el.scrollHeight }
            }
          </script>
        </div>
      </div>
    </div>

    <EnvTab.panel {assigns} />
    <div :if={@app_detail_tab == :runtime} id="runtime-packages" class="space-y-3">
      <div class="space-y-0.5">
        <h3 class="font-display text-xs font-semibold text-hd-text">Runtime packages</h3>
        <p class="text-[11px] text-hd-muted">
          Installed automatically on every deploy via apt.
        </p>
      </div>
      <div class="flex flex-wrap gap-2">
        <span
          :for={package <- @runtime_packages}
          class="rounded border border-hd-border bg-hd-aside px-2 py-0.5 font-mono text-[10px] text-hd-orange"
        >
          {package}
        </span>
      </div>
    </div>

    <div :if={@app_detail_tab == :webhook} id="app-webhook" class="space-y-5">
      <div class="space-y-3">
        <div class="space-y-0.5">
          <h3 class="font-display text-xs font-semibold text-hd-text">
            Deploy branch
          </h3>
          <p class="text-[11px] leading-relaxed text-hd-muted">
            Auto-deploy queues only when GitHub pushes this branch.
            Other refs are ignored.
          </p>
        </div>
        <.form
          for={@branch_form}
          id="deploy-branch-form"
          phx-change="validate_branch"
          phx-submit="save_branch"
          class="flex flex-col gap-2 sm:flex-row sm:items-end"
        >
          <div class="min-w-0 flex-1">
            <.input
              field={@branch_form[:branch]}
              id="app-deploy-branch-input"
              type="text"
              label="Branch"
              class="paas-input w-full font-mono"
              spellcheck="false"
              autocomplete="off"
            />
          </div>
          <button
            id="save-deploy-branch"
            type="submit"
            class="paas-btn-primary mb-2 shrink-0"
          >
            Save branch
          </button>
        </.form>
      </div>

      <div class="space-y-0.5">
        <h3 class="font-display text-xs font-semibold text-hd-text">
          GitHub Push webhook URL Credentials
        </h3>
        <p class="text-[11px] text-hd-muted">
          Configure these properties on GitHub (Repository Settings → Webhooks) to enable instant automatic deploys on push
        </p>
      </div>
      <div class="grid gap-3 md:grid-cols-2">
        <.copy_field id="webhook-url" label="Payload URL" value={@webhook_url} mono />
        <div class="space-y-1">
          <div class="flex items-center justify-between">
            <span class="font-mono text-[9px] font-semibold uppercase tracking-wider text-hd-muted">
              Webhook Secret token
            </span>
            <button
              type="button"
              phx-click="toggle_secret"
              class="text-[10px] text-hd-orange hover:underline"
            >
              {if @show_secret?, do: "Hide", else: "Reveal"}
            </button>
          </div>
          <.copy_field
            :if={@show_secret?}
            id="webhook-secret"
            label=""
            value={@app.webhook_secret}
            mono
          />
          <div
            :if={not @show_secret?}
            id="webhook-secret-masked"
            class="rounded border border-hd-border bg-hd-aside px-2.5 py-1.5 font-mono text-xs text-hd-muted/60"
          >
            {String.duplicate("•", 32)}
          </div>
        </div>
      </div>
    </div>

    <div :if={@app_detail_tab == :danger} id="app-danger-zone" class="space-y-4">
      <div class="space-y-0.5">
        <h3 class="font-display text-xs font-semibold text-rose-400">Danger zone</h3>
        <p class="text-[11px] leading-relaxed text-hd-muted">
          Permanently removes <span class="font-medium text-hd-text">{@app.name}</span>
          from Cleat — deploy history, env vars, and the GitHub webhook.
          The unit on {@app.server.name} is stopped and
          <span class="font-mono text-hd-text">{@app.release_path}</span>
          is deleted. This cannot be undone.
        </p>
      </div>

      <div class="rounded-lg border border-rose-500/30 bg-rose-500/5 p-4">
        <.form
          for={@delete_form}
          id="delete-app-form"
          phx-change="validate_delete"
          phx-submit="delete_app"
          class="space-y-3"
        >
          <p class="text-[11px] text-hd-muted">
            Type <span class="font-mono text-hd-text">{@app.slug}</span> to confirm.
          </p>
          <input
            id="delete-app-confirm"
            type="text"
            name={@delete_form[:confirm].name}
            value={@delete_form[:confirm].value}
            autocomplete="off"
            spellcheck="false"
            class="paas-input w-full font-mono"
            placeholder={@app.slug}
          />
          <button
            id="delete-app-button"
            type="submit"
            disabled={String.trim(@delete_confirm) != @app.slug or @deploying?}
            class="inline-flex items-center justify-center gap-1.5 rounded-md bg-rose-500 px-3 py-1.5 text-xs font-bold text-white transition-colors hover:bg-rose-400 disabled:cursor-not-allowed disabled:opacity-40"
          >
            <.icon name="hero-trash" class="size-3.5" /> Delete {@app.name}
          </button>
        </.form>
      </div>
    </div>
    """
  end
end
