defmodule CleatDeployWeb.AppLive.Layout.Addons do
  @moduledoc false
  use CleatDeployWeb, :html

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

  def addon_label("postgres:pgvector"), do: "Postgres"
  def addon_label("redis"), do: "Redis"
  def addon_label(addon), do: addon

  # `postgres:pgvector` is not usable in a CSS selector.
  def addon_id(addon), do: String.replace(addon, ":", "-")

  def addon_state(nil, _addon), do: :unknown

  def addon_state(%{error: _message}, _addon), do: :error

  def addon_state(status, addon) when is_map(status) do
    case Map.get(status, addon) do
      %{state: "ready"} -> :ready
      %{state: _other} -> :down
      nil -> :unknown
    end
  end

  def addon_detail(nil, _addon), do: "Checking the server…"
  def addon_detail(%{error: message}, _addon), do: "Could not check: #{message}"

  def addon_detail(status, addon) when is_map(status) do
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
end
