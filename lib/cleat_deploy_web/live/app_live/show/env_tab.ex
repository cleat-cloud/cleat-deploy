defmodule CleatDeployWeb.AppLive.Show.EnvTab do
  @moduledoc false
  use CleatDeployWeb, :html

  alias CleatDeploy.{Apps}
  alias CleatDeployWeb.AppLive.Show.Env

  def panel(assigns) do
    ~H"""
    <div :if={@app_detail_tab == :environment} id="app-env-vars" class="space-y-3">
      <div class="flex items-start justify-between gap-3">
        <div class="space-y-0.5">
          <h3 class="font-display text-xs font-semibold text-hd-text">
            Environment variables
          </h3>
          <p class="text-[11px] text-hd-muted">
            Synced to <span class="font-mono text-hd-orange">{@env_file}</span>
            on every deploy: variables for all branches plus the ones scoped to the branch
            being deployed. <span class="text-hd-text">PHX_HOST</span>
            is always injected from the app host ({@app.host}).
          </p>
        </div>
        <div class="flex shrink-0 items-center gap-3">
          <button
            :if={Enum.any?(@env_vars, & &1.sensitive?)}
            type="button"
            phx-click="toggle_env_values"
            class="text-[10px] text-hd-orange hover:underline"
          >
            {if @show_env_values?, do: "Hide secrets", else: "Reveal secrets"}
          </button>
          <button
            id="manage-env-vars-button"
            type="button"
            phx-click="open_env_modal"
            class="paas-btn-primary uppercase"
          >
            <.icon name="hero-plus" class="size-3.5" /> Manage variables
          </button>
        </div>
      </div>

      <div
        :if={@env_vars == []}
        class="rounded border border-dashed border-hd-border px-4 py-6 text-center text-xs text-hd-muted"
      >
        No environment variables configured yet.
      </div>

      <div :if={@env_vars != []} class="overflow-hidden rounded border border-hd-border">
        <table class="paas-table w-full text-left font-mono">
          <thead>
            <tr>
              <th>Branch</th>
              <th>Variable</th>
              <th>Value</th>
              <th></th>
            </tr>
          </thead>
          <tbody id="env-vars-list">
            <tr
              :for={env_var <- @env_vars}
              id={Env.env_var_row_id(env_var)}
              data-branch={env_var.branch}
            >
              <td class="align-top whitespace-nowrap text-[11px] text-hd-muted">
                {Env.branch_label(env_var.branch)}
              </td>
              <td class="align-top text-[11px] text-hd-orange">{env_var.key}</td>
              <td class="max-w-0">
                <span class="block truncate text-[11px] text-hd-text">
                  {Apps.display_env_value(env_var.key, env_var.value, @show_env_values?)}
                </span>
              </td>
              <td class="whitespace-nowrap text-right">
                <button
                  type="button"
                  phx-click="edit_env_var"
                  phx-value-key={env_var.key}
                  phx-value-branch={env_var.branch}
                  class="text-[10px] text-hd-orange hover:underline"
                >
                  Edit
                </button>
                <button
                  type="button"
                  phx-click="delete_env_var"
                  phx-value-key={env_var.key}
                  phx-value-branch={env_var.branch}
                  data-confirm={"Remove #{env_var.key} for #{Env.branch_label(env_var.branch)}?"}
                  class="ml-3 text-[10px] text-rose-400 hover:underline"
                >
                  Remove
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div
        :if={@env_modal_open?}
        id="env-var-modal"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        phx-window-keydown="close_env_modal"
        phx-key="Escape"
        role="presentation"
      >
        <button
          type="button"
          class="paas-modal-backdrop absolute inset-0 bg-black/70 backdrop-blur-sm"
          phx-click="close_env_modal"
          aria-label="Close environment variable form"
        />
        <div
          role="dialog"
          aria-modal="true"
          aria-labelledby="env-var-title"
          class="paas-modal-panel relative w-full max-w-lg overflow-hidden rounded-xl border border-hd-border bg-hd-card shadow-[0_24px_80px_rgba(0,0,0,0.55)]"
        >
          <div class="h-px bg-gradient-to-r from-transparent via-hd-orange/70 to-transparent" />
          <div class="space-y-4 p-5 sm:p-6">
            <div class="space-y-1">
              <h3 id="env-var-title" class="font-display text-base font-semibold text-hd-text">
                {if @editing_env_var?, do: "Edit variable", else: "New variable"}
              </h3>
              <p class="text-[13px] leading-relaxed text-hd-muted">
                The value is written to the env file on the next deploy of the branch it is
                scoped to.
              </p>
            </div>

            <.form
              for={@env_form}
              id="env-var-form"
              phx-change="validate_env"
              phx-submit="save_env_var"
              class="space-y-3"
            >
              <.input
                field={@env_form[:key]}
                id="env-var-key-input"
                type="text"
                label="Variable"
                placeholder="NEXT_PUBLIC_BASE_URL"
                class="paas-input w-full font-mono"
                spellcheck="false"
                autocomplete="off"
                required
              />
              <.input
                field={@env_form[:value]}
                id="env-var-value-input"
                type="textarea"
                label="Value"
                placeholder="https://example.com"
                class="paas-input w-full font-mono"
                rows="2"
                spellcheck="false"
                autocomplete="off"
                required
              />
              <.input
                field={@env_form[:branch]}
                id="env-var-branch-input"
                type="text"
                label="Branch"
                list="env-branch-options"
                placeholder="All branches"
                class="paas-input w-full font-mono"
                spellcheck="false"
                autocomplete="off"
              />
              <datalist id="env-branch-options">
                <option value="All branches"></option>
                <option :for={branch <- @env_branches} value={branch}></option>
              </datalist>
              <p class="text-[11px] text-hd-muted">
                Keep <span class="text-hd-text">All branches</span>
                to apply everywhere, or use a branch name to override only that branch.
              </p>

              <div class="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
                <button
                  :if={@editing_env_var?}
                  id="delete-env-var-button"
                  type="button"
                  phx-click="delete_env_var"
                  phx-value-key={@env_form[:key].value}
                  phx-value-branch={@env_form[:branch].value}
                  class="paas-btn-secondary justify-center text-rose-400"
                >
                  Remove
                </button>
                <button
                  type="button"
                  phx-click="close_env_modal"
                  class="paas-btn-secondary justify-center"
                >
                  Cancel
                </button>
                <button
                  id="save-env-var-button"
                  type="submit"
                  phx-disable-with="Saving…"
                  class="paas-btn-primary justify-center"
                >
                  Save variable
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
