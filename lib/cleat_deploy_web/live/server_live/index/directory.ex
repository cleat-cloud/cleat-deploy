defmodule CleatDeployWeb.ServerLive.Index.Directory do
  @moduledoc false
  use CleatDeployWeb, :html

  def grid(assigns) do
    ~H"""
    <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
      <div id="servers-list" phx-update="stream" class="contents">
        <div
          id="servers-empty"
          class="hidden only:block rounded-md border-2 border-dashed border-hd-border p-8 text-center md:col-span-2 lg:col-span-3"
        >
          <div class="mx-auto mb-4 flex size-12 animate-pulse items-center justify-center rounded-md border border-hd-border bg-hd-aside text-hd-orange">
            <.icon name="hero-server-stack" class="size-6" />
          </div>
          <h3 class="font-display text-sm font-semibold text-hd-text">
            No registered VM instances
          </h3>
          <p class="mx-auto mt-1 max-w-md text-xs leading-relaxed text-hd-muted">
            Register a Hetzner Cloud or AWS Lightsail VM with its SSH key to start deploying.
          </p>
          <.link navigate={~p"/servers/new"} class="paas-btn-primary mt-4 inline-flex">
            Register New Server
          </.link>
        </div>

        <div
          :for={{id, server} <- @streams.servers}
          id={id}
          class={[
            "paas-card flex flex-col justify-between p-4 transition-all hover:border-hd-orange/30",
            server.instance_status == "missing" && "border-rose-500/40"
          ]}
        >
          <.link navigate={~p"/servers/#{server.id}"} class="space-y-3">
            <div class="flex items-start justify-between">
              <div class="space-y-0.5">
                <h3 class="font-display text-xs font-semibold text-hd-text">{server.name}</h3>
                <div class="flex flex-wrap gap-1">
                  <span class="inline-block rounded border border-hd-border bg-hd-bg px-2 py-0.5 font-mono text-[9px] font-medium text-hd-orange">
                    {server.provider || "lightsail"}
                  </span>
                  <span class="inline-block rounded border border-hd-border bg-hd-bg px-2 py-0.5 font-mono text-[9px] font-medium text-hd-muted">
                    {server.region}
                  </span>
                  <span class={[
                    "inline-block rounded border px-2 py-0.5 font-mono text-[9px] font-medium",
                    server.deploy_mode == "dedicated" &&
                      "border-hd-orange/40 bg-hd-orange/10 text-hd-orange",
                    server.deploy_mode != "dedicated" && "border-hd-border bg-hd-bg text-hd-muted"
                  ]}>
                    {if server.deploy_mode == "dedicated", do: "Dedicated", else: "Shared"}
                  </span>
                </div>
              </div>
              <span class="flex items-center gap-1.5 rounded border border-hd-border bg-hd-bg px-2 py-0.5 font-mono text-[10px]">
                <span class={["size-1.5 rounded-full", status_dot_class(server.instance_status)]} />
                <span class={["font-semibold", status_text_class(server.instance_status)]}>
                  {status_label(server.instance_status)}
                </span>
              </span>
            </div>

            <div
              :if={CleatDeploy.Servers.Server.specs_configured?(server)}
              class="grid grid-cols-3 gap-2 font-mono text-[10px]"
            >
              <div class="rounded border border-hd-border bg-hd-bg px-2 py-1 text-center">
                <p class="text-hd-muted">Plan</p>
                <p class="font-semibold text-hd-text">{server.bundle_name}</p>
              </div>
              <div class="rounded border border-hd-border bg-hd-bg px-2 py-1 text-center">
                <p class="text-hd-muted">RAM</p>
                <p class="font-semibold text-hd-text">
                  {CleatDeploy.Servers.Server.format_ram(server)}
                </p>
              </div>
              <div class="rounded border border-hd-border bg-hd-bg px-2 py-1 text-center">
                <p class="text-hd-muted">vCPU</p>
                <p class="font-semibold text-hd-text">{server.cpu_count}</p>
              </div>
            </div>

            <div
              :if={not CleatDeploy.Servers.Server.specs_configured?(server)}
              class="rounded border border-dashed border-hd-border px-2.5 py-2 text-center text-[10px] text-hd-muted"
            >
              {status_hint(server.instance_status)}
            </div>

            <div class="flex items-center justify-between rounded border border-hd-border bg-hd-bg px-2.5 py-1.5 font-mono text-[11px]">
              <span class="text-hd-muted">Static IP:</span>
              <span class="font-bold tracking-wider text-hd-text">{server.host_ip}</span>
              <button
                id={"copy-ip-#{server.id}"}
                type="button"
                phx-hook=".Copy"
                data-clipboard={server.host_ip}
                class="text-hd-muted transition-colors hover:text-hd-text"
                aria-label="Copy IP"
              >
                <.icon name="hero-clipboard-document" class="size-3.5" />
              </button>
            </div>
          </.link>

          <button
            :if={removable_from_panel?(server, @app_counts)}
            id={"remove-server-#{server.id}"}
            type="button"
            phx-click="confirm_remove"
            phx-value-id={server.id}
            class="mt-3 w-full rounded border border-rose-500/40 px-2 py-1.5 font-mono text-[10px] font-semibold text-rose-400 transition-colors hover:bg-rose-500/10"
          >
            Remove from panel
          </button>
        </div>
      </div>

      <.link
        id="add-server-card"
        navigate={~p"/servers/new"}
        class="flex cursor-pointer flex-col items-center justify-center rounded-md border-2 border-dashed border-hd-border p-4 text-center transition-all hover:border-hd-muted hover:bg-hd-card/10"
      >
        <div class="flex size-8 items-center justify-center rounded-full border border-hd-border text-hd-muted">
          <.icon name="hero-plus" class="size-4" />
        </div>
        <p class="mt-1.5 text-[11px] font-semibold text-hd-text">Add server</p>
        <p class="text-[10px] text-hd-muted">Hetzner or Lightsail</p>
      </.link>
    </div>

    <div :if={@discovered != []} id="discovered-servers" class="space-y-3">
      <div>
        <h3 class="font-display text-sm font-semibold text-hd-text">Found in the cloud</h3>
        <p class="text-[11px] text-hd-muted">
          VMs in Hetzner or Lightsail that are not registered in this panel yet
        </p>
      </div>
      <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
        <div
          :for={remote <- @discovered}
          id={"discovered-#{remote.provider}-#{remote.name}"}
          class="paas-card space-y-3 p-4"
        >
          <div class="flex items-start justify-between gap-2">
            <div>
              <h4 class="font-display text-xs font-semibold text-hd-text">{remote.name}</h4>
              <p class="font-mono text-[11px] text-hd-muted">
                {remote.provider} · {remote.region || "—"}
              </p>
            </div>
            <span class="font-mono text-[10px] font-semibold text-hd-green">NEW</span>
          </div>
          <p class="font-mono text-[11px] text-hd-text">{remote.public_ip || "no public IPv4"}</p>
          <button
            id={"register-#{remote.provider}-#{remote.name}"}
            type="button"
            phx-click="register_discovered"
            phx-value-name={remote.name}
            phx-value-host_ip={remote.public_ip}
            phx-value-provider={remote.provider}
            phx-value-region={remote.region}
            class="paas-btn-secondary w-full"
          >
            Register
          </button>
        </div>
      </div>
    </div>

    <div
      :if={@confirming_server}
      id="remove-confirm-modal"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      phx-window-keydown="cancel_remove"
      phx-key="Escape"
      role="presentation"
    >
      <button
        type="button"
        class="paas-modal-backdrop absolute inset-0 bg-black/70 backdrop-blur-sm"
        phx-click="cancel_remove"
        aria-label="Close confirmation"
      />
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="remove-confirm-title"
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
                id="remove-confirm-title"
                class="font-display text-base font-semibold text-hd-text"
              >
                Remove this server?
              </h3>
              <p class="text-[13px] leading-relaxed text-hd-muted">
                It is not in Hetzner or Lightsail. This only drops it from the panel — the
                machine is not deleted.
              </p>
            </div>
          </div>

          <div class="rounded-lg border border-hd-border bg-hd-aside px-3 py-3">
            <p class="font-display text-sm font-semibold text-hd-text">
              {@confirming_server.name}
            </p>
            <p class="mt-1 font-mono text-[11px] text-hd-muted">
              {@confirming_server.provider} · {@confirming_server.region} · {@confirming_server.host_ip}
            </p>
          </div>

          <div class="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
            <button
              id="cancel-remove-server"
              type="button"
              phx-click="cancel_remove"
              class="paas-btn-secondary justify-center"
            >
              Keep it
            </button>
            <button
              id="confirm-remove-server"
              type="button"
              phx-click="remove_server"
              phx-disable-with="Removing…"
              class="inline-flex items-center justify-center gap-1.5 rounded-md bg-rose-500 px-3 py-1.5 text-xs font-bold text-white transition-colors hover:bg-rose-400"
            >
              <.icon name="hero-trash" class="size-3.5" /> Yes, remove it
            </button>
          </div>
        </div>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Copy">
      export default {
        mounted() {
          this.el.addEventListener("click", (event) => {
            event.preventDefault();
            event.stopPropagation();
            navigator.clipboard.writeText(this.el.dataset.clipboard || "");
          });
        }
      }
    </script>
    """
  end

  def status_label(nil), do: "UNKNOWN"
  def status_label(status), do: String.upcase(status)

  def status_dot_class("running"), do: "animate-pulse bg-hd-green"
  def status_dot_class("missing"), do: "bg-rose-500"
  def status_dot_class("private"), do: "bg-sky-400"
  def status_dot_class(_), do: "bg-hd-muted"

  def status_text_class("missing"), do: "text-rose-400"
  def status_text_class("running"), do: "text-hd-green"
  def status_text_class("private"), do: "text-sky-400"
  def status_text_class(_), do: "text-hd-muted"

  def status_hint("missing"), do: "Gone from Hetzner / Lightsail"
  def status_hint("private"), do: "Private network — not in the cloud APIs"
  def status_hint(_), do: "Open to sync cloud specs"

  def removable_from_panel?(server, app_counts) do
    server.instance_status in ["missing", "private"] and Map.get(app_counts, server.id, 0) == 0
  end
end
