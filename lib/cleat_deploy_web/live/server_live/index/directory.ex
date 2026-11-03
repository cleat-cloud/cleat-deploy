defmodule CleatDeployWeb.ServerLive.Index.Directory do
  @moduledoc false
  use CleatDeployWeb, :html

  def grid(assigns) do
    ~H"""
    <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
      <div id="servers-list" phx-update="stream" class="contents">
        <div
          id="servers-empty"
          class="hidden only:block rounded-xl border border-dashed border-hd-border p-8 text-center md:col-span-2 lg:col-span-3"
        >
          <div class="mx-auto mb-4 flex size-12 items-center justify-center rounded-xl border border-hd-border bg-hd-aside text-hd-muted">
            <.icon name="hero-server-stack" class="size-6" />
          </div>
          <h3 class="text-[15px] font-medium text-hd-text">
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
            "paas-card flex flex-col justify-between p-5 transition-colors hover:border-hd-text/20",
            server.instance_status == "missing" && "border-hd-red/40"
          ]}
        >
          <.link navigate={~p"/servers/#{server.id}"} class="space-y-4">
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0 space-y-1">
                <h3 class="truncate text-[15px] font-medium text-hd-text">{server.name}</h3>
                <p class="font-mono text-xs text-hd-muted">
                  {server.provider || "lightsail"} · {server.region}
                  <span class="text-hd-muted/50">·</span>
                  {if server.deploy_mode == "dedicated", do: "Dedicated", else: "Shared"}
                </p>
              </div>
              <span class="mt-0.5 flex shrink-0 items-center gap-1.5 text-xs">
                <span class={["size-1.5 rounded-full", status_dot_class(server.instance_status)]} />
                <span class={status_text_class(server.instance_status)}>
                  {status_label(server.instance_status)}
                </span>
              </span>
            </div>

            <p
              :if={CleatDeploy.Servers.Server.specs_configured?(server)}
              class="font-mono text-xs text-hd-muted"
            >
              {server.bundle_name} · {server.cpu_count} vCPU · {CleatDeploy.Servers.Server.format_ram(
                server
              )}
            </p>

            <p
              :if={not CleatDeploy.Servers.Server.specs_configured?(server)}
              class="text-xs text-hd-muted"
            >
              {status_hint(server.instance_status)}
            </p>

            <div class="flex items-center justify-between border-t border-hd-border/60 pt-3">
              <span class="text-xs text-hd-muted">Static IP</span>
              <span class="flex items-center gap-1.5 font-mono text-xs text-hd-secondary">
                {server.host_ip}
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
              </span>
            </div>
          </.link>

          <button
            :if={removable_from_panel?(server, @app_counts)}
            id={"remove-server-#{server.id}"}
            type="button"
            phx-click="confirm_remove"
            phx-value-id={server.id}
            class="mt-4 w-full rounded-lg border border-hd-red/40 px-2 py-1.5 text-xs text-hd-red transition-colors hover:bg-hd-red/10"
          >
            Remove from panel
          </button>
        </div>
      </div>

      <.link
        id="add-server-card"
        navigate={~p"/servers/new"}
        class="flex min-h-40 cursor-pointer flex-col items-center justify-center rounded-xl border border-dashed border-hd-border p-4 text-center transition-colors hover:border-hd-text/25"
      >
        <div class="flex size-8 items-center justify-center rounded-full border border-hd-border text-hd-muted">
          <.icon name="hero-plus" class="size-4" />
        </div>
        <p class="mt-2 text-[13px] font-medium text-hd-text">Add server</p>
        <p class="text-xs text-hd-muted">Hetzner or Lightsail</p>
      </.link>
    </div>

    <div :if={@discovered != []} id="discovered-servers" class="mt-6 space-y-3">
      <div>
        <h3 class="text-[15px] font-medium text-hd-text">Found in the cloud</h3>
        <p class="text-xs text-hd-muted">
          VMs in Hetzner or Lightsail that are not registered in this panel yet
        </p>
      </div>
      <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
        <div
          :for={remote <- @discovered}
          id={"discovered-#{remote.provider}-#{remote.name}"}
          class="paas-card space-y-3 p-5"
        >
          <div class="flex items-start justify-between gap-2">
            <div>
              <h4 class="text-[15px] font-medium text-hd-text">{remote.name}</h4>
              <p class="font-mono text-xs text-hd-muted">
                {remote.provider} · {remote.region || "—"}
              </p>
            </div>
            <span class="flex items-center gap-1.5 text-xs text-hd-green">
              <span class="size-1.5 rounded-full bg-hd-green" /> new
            </span>
          </div>
          <p class="font-mono text-xs text-hd-secondary">{remote.public_ip || "no public IPv4"}</p>
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
        class="paas-modal-panel relative w-full max-w-md overflow-hidden rounded-xl border border-hd-border bg-hd-card shadow-2xl"
      >
        <div class="space-y-5 p-5 sm:p-6">
          <div class="flex items-start gap-3">
            <div class="flex size-11 shrink-0 items-center justify-center rounded-full border border-hd-border bg-hd-raised text-hd-muted">
              <.icon name="hero-exclamation-triangle" class="size-5" />
            </div>
            <div class="min-w-0 space-y-1">
              <h3
                id="remove-confirm-title"
                class="text-base font-medium text-hd-text"
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
            <p class="text-[13px] font-medium text-hd-text">
              {@confirming_server.name}
            </p>
            <p class="mt-1 font-mono text-xs text-hd-muted">
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
              class="inline-flex items-center justify-center gap-1.5 rounded-lg bg-hd-red px-3 py-1.5 text-[13px] font-medium text-white transition-colors hover:opacity-90"
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

  def status_label(nil), do: "unknown"
  def status_label(status), do: status

  def status_dot_class("running"), do: "bg-hd-green"
  def status_dot_class("missing"), do: "bg-hd-red"
  def status_dot_class("private"), do: "bg-hd-muted"
  def status_dot_class(_), do: "bg-hd-muted/50"

  def status_text_class("missing"), do: "text-hd-red"
  def status_text_class("running"), do: "text-hd-green"
  def status_text_class(_), do: "text-hd-muted"

  def status_hint("missing"), do: "Gone from Hetzner / Lightsail"
  def status_hint("private"), do: "Private network — not in the cloud APIs"
  def status_hint(_), do: "Open to sync cloud specs"

  def removable_from_panel?(server, app_counts) do
    server.instance_status in ["missing", "private"] and Map.get(app_counts, server.id, 0) == 0
  end
end
