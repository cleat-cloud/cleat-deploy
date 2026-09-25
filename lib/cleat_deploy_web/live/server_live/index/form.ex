defmodule CleatDeployWeb.ServerLive.Index.Form do
  @moduledoc false
  use CleatDeployWeb, :html

  alias CleatDeploy.Hetzner.Catalog
  alias CleatDeploy.Servers.Provision

  def register_form(assigns) do
    ~H"""
    <div :if={@live_action == :new} class="paas-card overflow-hidden">
      <div class="flex flex-wrap items-center justify-between gap-3 border-b border-hd-border px-4 py-3">
        <div>
          <h3 class="font-display text-sm font-semibold text-hd-text">New Hetzner VM</h3>
          <p class="text-[11px] text-hd-muted">
            Creates a real Ubuntu box in Hetzner Cloud and registers it here
          </p>
        </div>
        <div class="flex rounded-md border border-hd-border bg-hd-aside p-0.5 text-[11px] font-semibold">
          <button
            id="form-mode-create"
            type="button"
            phx-click="set_form_mode"
            phx-value-mode="create"
            class={[
              "rounded px-2.5 py-1 transition-colors",
              @form_mode != :register && "bg-hd-card text-hd-text",
              @form_mode == :register && "text-hd-muted hover:text-hd-text"
            ]}
          >
            Create in cloud
          </button>
          <button
            id="form-mode-register"
            type="button"
            phx-click="set_form_mode"
            phx-value-mode="register"
            class={[
              "rounded px-2.5 py-1 transition-colors",
              @form_mode == :register && "bg-hd-card text-hd-text",
              @form_mode != :register && "text-hd-muted hover:text-hd-text"
            ]}
          >
            Register existing
          </button>
        </div>
      </div>

      <div :if={@form_mode != :register} class="space-y-5 p-4">
        <.form
          for={@form}
          id="create-server-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-5"
        >
          <input type="hidden" name={@form[:provider].name} value="hetzner" />
          <div class="grid gap-4 sm:grid-cols-2">
            <.input
              field={@form[:name]}
              type="text"
              label="Server name"
              placeholder="gestaobem-cx33"
              required
            />
            <.input
              field={@form[:region]}
              type="select"
              label="Location"
              options={Provision.locations()}
            />
          </div>

          <div class="space-y-2">
            <div class="flex items-center justify-between gap-3">
              <p class="font-mono text-[10px] font-semibold uppercase tracking-wider text-hd-muted">
                Plan
              </p>
              <div
                id="plan-currency"
                class="flex rounded-md border border-hd-border bg-hd-aside p-0.5 text-[11px] font-semibold"
                role="group"
                aria-label="Plan currency"
              >
                <button
                  id="plan-currency-eur"
                  type="button"
                  phx-click="set_plan_currency"
                  phx-value-currency="eur"
                  aria-pressed={@plan_currency == :eur}
                  class={[
                    "rounded px-2.5 py-1 transition-colors",
                    @plan_currency == :eur && "bg-hd-card text-hd-text",
                    @plan_currency != :eur && "text-hd-muted hover:text-hd-text"
                  ]}
                >
                  € EUR
                </button>
                <button
                  id="plan-currency-usd"
                  type="button"
                  phx-click="set_plan_currency"
                  phx-value-currency="usd"
                  aria-pressed={@plan_currency == :usd}
                  class={[
                    "rounded px-2.5 py-1 transition-colors",
                    @plan_currency == :usd && "bg-hd-card text-hd-text",
                    @plan_currency != :usd && "text-hd-muted hover:text-hd-text"
                  ]}
                >
                  $ USD
                </button>
              </div>
            </div>
            <div id="bundle-picker" class="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
              <label
                :for={bundle <- Provision.bundles()}
                id={"bundle-#{bundle.bundle_id}"}
                class={[
                  "relative cursor-pointer rounded-lg border p-3 transition-all",
                  @form[:bundle_id].value == bundle.bundle_id &&
                    "border-hd-orange bg-hd-orange/10",
                  @form[:bundle_id].value != bundle.bundle_id &&
                    "border-hd-border bg-hd-aside hover:border-hd-muted"
                ]}
              >
                <input
                  type="radio"
                  name={@form[:bundle_id].name}
                  value={bundle.bundle_id}
                  checked={@form[:bundle_id].value == bundle.bundle_id}
                  class="sr-only"
                />
                <div class="flex items-start justify-between gap-2">
                  <p class="font-display text-sm font-semibold text-hd-text">
                    {bundle.bundle_name}
                  </p>
                  <span
                    :if={bundle.bundle_id == "cx33"}
                    class="rounded-full border border-hd-orange/40 px-1.5 py-0.5 font-mono text-[9px] uppercase tracking-wide text-hd-orange"
                  >
                    Rec
                  </span>
                </div>
                <p class="mt-1 font-mono text-[11px] text-hd-muted">
                  {bundle.cpu_count} vCPU · {CleatDeploy.Servers.Server.format_ram(
                    %CleatDeploy.Servers.Server{ram_mb: bundle.ram_mb}
                  )} · {bundle.disk_gb} GB
                </p>
                <p
                  id={"bundle-#{bundle.bundle_id}-price"}
                  class="mt-2 font-mono text-xs font-semibold text-hd-text"
                >
                  {Catalog.format_price(bundle, @plan_currency)}
                </p>
              </label>
            </div>
            <p :if={@plan_currency == :usd} class="text-[10px] text-hd-muted">
              Estimate · Hetzner bills in euro (€1 = $1.16)
            </p>
          </div>

          <.input
            field={@form[:deploy_mode]}
            type="select"
            label="Deploy mode"
            options={[
              {"Shared (multiple apps)", "shared"},
              {"Dedicated (solo app)", "dedicated"}
            ]}
          />

          <p class="text-[11px] leading-relaxed text-hd-muted">
            Ubuntu 24.04, user <span class="font-mono text-hd-text">ubuntu</span>, SSH key
            reused from an existing server or generated automatically. Public IPv4 comes
            from Hetzner after the VM boots.
          </p>

          <div class="flex gap-2">
            <button
              type="submit"
              class="paas-btn-primary"
              phx-disable-with="Creating in Hetzner…"
            >
              <.icon name="hero-cloud" class="size-3.5" /> Create VM
            </button>
            <.link navigate={~p"/servers"} class="paas-btn-secondary">Cancel</.link>
          </div>
        </.form>
      </div>

      <div :if={@form_mode == :register} class="space-y-4 p-4">
        <p class="text-[11px] text-hd-muted">
          Use this only for a box that already exists (Tailscale or an imported IP).
        </p>
        <.form
          for={@form}
          id="server-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-4"
        >
          <div class="grid gap-4 sm:grid-cols-2">
            <.input field={@form[:name]} type="text" label="Name" required />
            <.input field={@form[:host_ip]} type="text" label="Host IP" required />
            <.input
              field={@form[:provider]}
              type="select"
              label="Provider"
              options={[
                {"Hetzner Cloud", "hetzner"},
                {"AWS Lightsail", "lightsail"}
              ]}
            />
            <.input field={@form[:ssh_user]} type="text" label="SSH user" />
            <.input field={@form[:region]} type="text" label="Region / location" />
            <.input
              field={@form[:aws_instance_name]}
              type="text"
              label="Instance name"
            />
            <.input
              field={@form[:deploy_mode]}
              type="select"
              label="Deploy mode"
              options={[
                {"Shared (multiple apps)", "shared"},
                {"Dedicated (solo app)", "dedicated"}
              ]}
            />
            <.input
              field={@form[:ssh_private_key]}
              type="textarea"
              label="SSH private key (PEM)"
              class="col-span-full font-mono text-xs"
              placeholder="-----BEGIN OPENSSH PRIVATE KEY-----"
            />
          </div>
          <div class="flex gap-2">
            <button type="submit" class="paas-btn-primary">Save server</button>
            <.link navigate={~p"/servers"} class="paas-btn-secondary">Cancel</.link>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
