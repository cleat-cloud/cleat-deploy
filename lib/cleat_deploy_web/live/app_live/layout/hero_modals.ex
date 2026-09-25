defmodule CleatDeployWeb.AppLive.Layout.HeroModals do
  @moduledoc false
  use CleatDeployWeb, :html

  # Tooltip for the auto sleep chip in the hero: state, window and the two
  # caveats (needs a deploy; the platform switch can be off).
  def idle_hint(assigns) do
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
  def idle_confirm_hint(assigns) do
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

  def idle_window(assigns) do
    case assigns[:minutes] do
      minutes when is_integer(minutes) -> "#{minutes} min"
      _ -> "the platform window"
    end
  end

  def modals(assigns) do
    ~H"""
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
    <div
      :if={@confirming_new_instance?}
      id="new-instance-modal"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      phx-window-keydown="close_new_instance"
      phx-key="Escape"
      role="presentation"
    >
      <button
        type="button"
        class="paas-modal-backdrop absolute inset-0 bg-black/70 backdrop-blur-sm"
        phx-click="close_new_instance"
        aria-label="Close new instance form"
      />
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="new-instance-title"
        class="paas-modal-panel relative w-full max-w-lg overflow-hidden rounded-xl border border-hd-border bg-hd-card shadow-[0_24px_80px_rgba(0,0,0,0.55)]"
      >
        <div class="h-px bg-gradient-to-r from-transparent via-hd-blue/70 to-transparent" />
        <div class="space-y-4 p-5 sm:p-6">
          <div class="space-y-1">
            <h3 id="new-instance-title" class="font-display text-base font-semibold text-hd-text">
              New instance
            </h3>
            <p class="text-[13px] leading-relaxed text-hd-muted">
              Registers another instance of
              <span class="font-mono text-hd-orange">{@app.github_repo}</span>
              on a different branch, with its own slug, host, port, systemd unit and environment
              variables. Pushes keep deploying both instances.
            </p>
          </div>

          <div
            :if={@instance_errors != []}
            id="new-instance-errors"
            class="space-y-1 rounded-lg border border-rose-500/40 bg-rose-500/10 px-3 py-2 text-[11px] text-rose-300"
          >
            <p :for={error <- @instance_errors}>{error}</p>
          </div>

          <.form
            for={@instance_form}
            id="new-instance-form"
            phx-change="validate_new_instance"
            phx-submit="save_new_instance"
            class="space-y-3"
          >
            <.input
              field={@instance_form[:branch]}
              id="instance-branch-input"
              type="text"
              label="Branch"
              placeholder="staging"
              class="paas-input w-full font-mono"
              spellcheck="false"
              autocomplete="off"
              required
            />
            <.input
              field={@instance_form[:name]}
              id="instance-name-input"
              type="text"
              label="Name"
              placeholder={@instance_defaults.name}
              class="paas-input w-full"
              autocomplete="off"
            />
            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                field={@instance_form[:slug]}
                id="instance-slug-input"
                type="text"
                label="Slug"
                placeholder={@instance_defaults.slug}
                class="paas-input w-full font-mono"
                spellcheck="false"
                autocomplete="off"
              />
              <.input
                field={@instance_form[:port]}
                id="instance-port-input"
                type="number"
                label="Port"
                placeholder="first free port"
                class="paas-input w-full font-mono"
              />
            </div>
            <.input
              field={@instance_form[:host]}
              id="instance-host-input"
              type="text"
              label="Host"
              placeholder={@instance_defaults.host}
              class="paas-input w-full font-mono"
              spellcheck="false"
              autocomplete="off"
            />
            <p class="text-[11px] text-hd-muted">
              Blank fields use the suggestion shown in grey. Deployed to
              <span class="text-hd-text">{@app.server.name}</span>
              with the {@app.runtime} runtime, same as this instance.
            </p>

            <div class="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
              <button
                type="button"
                phx-click="close_new_instance"
                class="paas-btn-secondary justify-center"
              >
                Cancel
              </button>
              <button
                id="save-new-instance-button"
                type="submit"
                phx-disable-with="Creating…"
                class="paas-btn-primary justify-center"
              >
                Create instance
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
