defmodule CleatDeployWeb.AppLive.Index.Modals do
  @moduledoc false
  use CleatDeployWeb, :html

  alias CleatDeploy.Apps.{App, RuntimeControl}

  def dialogs(assigns) do
    ~H"""
    <div
      :if={@pending_delete}
      id="apps-delete-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
    >
      <div class="paas-modal-panel w-full max-w-md rounded-xl border border-hd-red/40 bg-hd-card p-5 shadow-xl">
        <h3 class="flex items-center gap-2 text-[15px] font-medium text-hd-text">
          <.icon name="hero-exclamation-triangle" class="size-4 text-hd-red" />
          Delete {@pending_delete.name}?
        </h3>
        <p class="mt-2 text-[13px] leading-relaxed text-hd-muted">
          Permanently removes the app from Cleat — deploy history, env vars, and the GitHub
          webhook. The unit on {@pending_delete.server.name} is stopped and
          <span class="font-mono text-hd-text">{@pending_delete.release_path}</span>
          is deleted. This cannot be undone.
        </p>
        <.form
          for={@delete_form}
          id="apps-delete-form"
          phx-change="validate_delete"
          phx-submit="delete_app"
          class="mt-4 space-y-3"
        >
          <p class="text-[13px] text-hd-muted">
            Type <span class="font-mono text-hd-text">{@pending_delete.slug}</span> to confirm.
          </p>
          <input
            id="apps-delete-confirm"
            type="text"
            name={@delete_form[:confirm].name}
            value={@delete_form[:confirm].value}
            autocomplete="off"
            spellcheck="false"
            class="paas-input w-full font-mono"
            placeholder={@pending_delete.slug}
          />
          <div class="flex items-center justify-end gap-2">
            <button
              type="button"
              id="apps-keep-button"
              phx-click="cancel_delete"
              class="paas-btn-secondary"
            >
              Cancel
            </button>
            <button
              id="apps-delete-button"
              type="submit"
              disabled={String.trim(@delete_confirm) != @pending_delete.slug}
              class="inline-flex items-center justify-center gap-1.5 rounded-lg bg-hd-red px-3 py-1.5 text-[13px] font-medium text-white transition-colors hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-40"
            >
              <.icon name="hero-trash" class="size-3.5" /> Delete app
            </button>
          </div>
        </.form>
      </div>
    </div>

    <div
      :if={@pending_hibernate}
      id="apps-hibernate-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
      phx-window-keydown="close_hibernate"
      phx-key="Escape"
      role="presentation"
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="apps-hibernate-title"
        class="paas-modal-panel w-full max-w-md rounded-xl border border-hd-border bg-hd-card p-5 shadow-xl"
      >
        <h3
          id="apps-hibernate-title"
          class="flex items-center gap-2 text-[15px] font-medium text-hd-text"
        >
          <.icon name="hero-moon" class="size-4 text-hd-muted" /> Hibernate {@pending_hibernate.name}?
        </h3>
        <p class="mt-2 text-[13px] leading-relaxed text-hd-muted">
          The process is stopped, so it stops using CPU and RAM. The release, the data
          directory and the Caddy site stay on disk — nothing is rebuilt to bring it back. {RuntimeControl.wake_hint(
            @pending_hibernate
          )}
        </p>
        <div class="mt-3 rounded-lg border border-hd-border bg-hd-aside px-3 py-2">
          <p class="font-mono text-xs text-hd-text">{@pending_hibernate.host}</p>
          <p class="mt-0.5 font-mono text-[11px] text-hd-muted">
            unit {App.unit_name(@pending_hibernate)}
          </p>
        </div>
        <div class="mt-4 flex items-center justify-end gap-2">
          <button
            type="button"
            id="apps-keep-hibernate-button"
            phx-click="close_hibernate"
            class="paas-btn-secondary"
          >
            Keep it running
          </button>
          <button
            id="apps-confirm-hibernate-button"
            type="button"
            phx-click="hibernate_app"
            phx-value-id={@pending_hibernate.id}
            phx-disable-with="Hibernating…"
            class="paas-btn-primary justify-center"
          >
            <.icon name="hero-moon" class="size-3.5" /> Yes, hibernate
          </button>
        </div>
      </div>
    </div>
    """
  end
end
