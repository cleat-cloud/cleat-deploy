defmodule CleatDeployWeb.SettingsLive do
  use CleatDeployWeb, :live_view

  alias CleatDeploy.{Accounts, Apps, Settings}
  alias CleatDeploy.Settings.Setting

  @impl true
  def mount(_params, session, socket) do
    scope = socket.assigns.current_scope
    user = scope.user
    setting = Settings.get_setting(scope)

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:active_tab, :settings)
     |> assign(:settings_tab, :platform)
     |> assign(:setting, setting)
     |> assign(:idle_form, to_form(Settings.change_setting(setting), as: :setting))
     |> assign(:armed_count, length(Apps.list_idle_candidates(scope.tenant.id)))
     |> assign(:email_form, to_form(Accounts.change_user_email(user)))
     |> assign(:password_form, to_form(Accounts.change_user_password(user)))
     |> assign(:user_token, session["user_token"])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :settings_tab, parse_tab(params["tab"]))}
  end

  @impl true
  def handle_event("save_idle_shutdown", %{"setting" => params}, socket) do
    case Settings.update_setting(socket.assigns.current_scope, params) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:idle_form, to_form(Settings.change_setting(setting), as: :setting))
         |> put_flash(:info, "Settings saved")}

      {:error, changeset} ->
        form =
          changeset
          |> Map.put(:action, :validate)
          |> to_form(as: :setting)

        {:noreply, assign(socket, :idle_form, form)}
    end
  end

  def handle_event("update_email", %{"user" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.change_user_email(user, params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &update_email_url/1
        )

        {:noreply,
         socket
         |> assign(:email_form, to_form(Accounts.change_user_email(user)))
         |> put_flash(
           :info,
           "A link to confirm your email change has been sent to the new address."
         )}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(%{changeset | action: :insert}))}
    end
  end

  def handle_event("update_password", %{"user" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.update_user_password(user, params,
           keep_session_token: socket.assigns.user_token
         ) do
      {:ok, {_user, _}} ->
        {:noreply,
         socket
         |> assign(:password_form, to_form(Accounts.change_user_password(user)))
         |> put_flash(:info, "Password updated successfully.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :password_form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_tab={@active_tab}
      server_count={@server_count}
      app_count={@app_count}
    >
      <div id="settings" class="mx-auto max-w-3xl space-y-4">
        <div class="space-y-1">
          <h2 class="font-display text-lg font-semibold tracking-tight text-hd-text">Settings</h2>
          <p class="text-xs text-hd-muted">
            Signed in as <span class="font-mono text-hd-text">{@current_scope.user.email}</span>
          </p>
        </div>

        <div class="paas-card overflow-hidden">
          <div
            id="settings-tabs"
            role="tablist"
            aria-label="Settings"
            class="flex flex-wrap items-center gap-1 border-b border-hd-border bg-hd-aside p-1"
          >
            <.settings_tab
              tab={:platform}
              label="Platform"
              icon="hero-cog-6-tooth"
              active?={@settings_tab == :platform}
              href={~p"/settings?tab=platform"}
            />
            <.settings_tab
              tab={:account}
              label="Account"
              icon="hero-user-circle"
              active?={@settings_tab == :account}
              href={~p"/settings?tab=account"}
            />
          </div>

          <div :if={@settings_tab == :platform} id="settings-platform" class="space-y-4 p-4">
            <div class="space-y-1">
              <h3 class="font-display text-xs font-semibold text-hd-text">
                Auto sleep · idle shutdown
              </h3>
              <p class="text-[11px] leading-relaxed text-hd-muted">
                Applies to every app of this tenant. Apps with the per-app flag on are stopped
                after this window without any request; the next request starts them again (cold
                start) — the wake agent runs on the server, so waking does not depend on this panel.
              </p>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <span class={[
                "rounded border px-2 py-0.5 font-mono text-[10px] font-semibold uppercase tracking-wide",
                @setting.idle_shutdown_enabled &&
                  "border-hd-green/40 bg-hd-green/10 text-hd-green",
                !@setting.idle_shutdown_enabled &&
                  "border-hd-border bg-hd-aside text-hd-muted"
              ]}>
                {if @setting.idle_shutdown_enabled, do: "Enabled", else: "Disabled"}
              </span>
            </div>

            <.form
              for={@idle_form}
              id="idle-shutdown-form"
              phx-submit="save_idle_shutdown"
              class="space-y-3"
            >
              <.input
                field={@idle_form[:idle_shutdown_enabled]}
                id="idle-shutdown-enabled"
                type="checkbox"
                label="Stop idle apps automatically"
              />

              <div class="max-w-xs">
                <.input
                  field={@idle_form[:idle_shutdown_minutes]}
                  id="idle-shutdown-minutes"
                  type="number"
                  min={Setting.min_minutes()}
                  max={Setting.max_minutes()}
                  step="1"
                  label="Idle window (minutes)"
                  class="paas-input w-full font-mono"
                />
              </div>

              <button id="save-idle-shutdown" type="submit" class="paas-btn-primary">
                <.icon name="hero-check" class="size-3.5" /> Save
              </button>
            </.form>

            <div
              id="idle-shutdown-hint"
              class="rounded border border-hd-border bg-hd-aside px-3 py-2 text-[11px] leading-relaxed text-hd-muted"
            >
              <p>
                <span class="font-mono text-hd-text">{@armed_count}</span>
                {if @armed_count == 1, do: "app has", else: "apps have"} the per-app flag on.
                <.link navigate={~p"/apps"} class="text-hd-orange hover:underline">
                  Open the apps list
                </.link>
                and enable <span class="font-mono text-hd-text">Auto sleep</span>
                in each app you want to include.
              </p>
              <p class="mt-1">
                Waking only works on apps deployed after the flag was turned on: the deploy installs
                the wake agent and arms the app. Until then the app is ignored by the sweeper.
              </p>
            </div>
          </div>

          <div :if={@settings_tab == :account} id="settings-account" class="space-y-4 p-4">
            <.settings_section
              icon="hero-envelope"
              title="Email address"
              description="We'll send a confirmation link to your new address before the change takes effect."
            >
              <.form
                for={@email_form}
                id="update_email"
                phx-submit="update_email"
                class="space-y-4"
              >
                <.input
                  field={@email_form[:email]}
                  type="email"
                  label="New email"
                  autocomplete="username"
                  spellcheck="false"
                  required
                />

                <.button class="paas-btn-primary w-full justify-center py-2.5">
                  Send confirmation link
                </.button>
              </.form>
            </.settings_section>

            <.settings_section
              icon="hero-lock-closed"
              title="Password"
              description="Use a strong password you don't reuse elsewhere. You'll stay signed in after updating."
            >
              <.form
                for={@password_form}
                id="update_password"
                phx-submit="update_password"
                class="space-y-4"
              >
                <div class="space-y-3">
                  <.input
                    field={@password_form[:password]}
                    type="password"
                    label="New password"
                    autocomplete="new-password"
                    spellcheck="false"
                    required
                  />
                  <.input
                    field={@password_form[:password_confirmation]}
                    type="password"
                    label="Confirm new password"
                    autocomplete="new-password"
                    spellcheck="false"
                    required
                  />
                </div>

                <ul class="space-y-1.5 rounded-md border border-hd-border bg-hd-aside/50 px-3 py-2.5">
                  <.password_requirement label="At least 12 characters" />
                  <.password_requirement label="Confirmation must match" />
                </ul>

                <.button class="paas-btn-primary w-full justify-center py-2.5">
                  Update password
                </.button>
              </.form>
            </.settings_section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :tab, :atom, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :active?, :boolean, required: true
  attr :href, :string, required: true

  defp settings_tab(assigns) do
    ~H"""
    <.link
      id={"settings-tab-#{@tab}"}
      navigate={@href}
      role="tab"
      aria-selected={@active?}
      class={[
        "flex items-center gap-1.5 rounded-md px-3 py-1.5 text-xs font-semibold tracking-wide transition-all",
        @active? && "border border-hd-border bg-hd-card text-hd-orange",
        !@active? && "text-hd-muted hover:text-hd-text"
      ]}
    >
      <.icon name={@icon} class="size-3.5" />
      <span>{@label}</span>
    </.link>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  slot :inner_block, required: true

  defp settings_section(assigns) do
    ~H"""
    <section class="paas-card overflow-hidden">
      <div class="flex items-start gap-3 border-b border-hd-border bg-hd-aside/60 px-4 py-3.5">
        <div class="flex size-9 shrink-0 items-center justify-center rounded-md border border-hd-border bg-hd-card">
          <.icon name={@icon} class="size-4 text-hd-orange" />
        </div>
        <div class="min-w-0 space-y-0.5">
          <h3 class="font-display text-sm font-semibold text-hd-text">{@title}</h3>
          <p class="text-xs leading-relaxed text-hd-muted">{@description}</p>
        </div>
      </div>
      <div class="p-4">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr :label, :string, required: true

  defp password_requirement(assigns) do
    ~H"""
    <li class="flex items-center gap-2 text-xs text-hd-muted">
      <.icon name="hero-check-circle" class="size-3.5 shrink-0 text-hd-green/80" />
      {@label}
    </li>
    """
  end

  defp parse_tab("account"), do: :account
  defp parse_tab(_tab), do: :platform

  defp update_email_url(token) do
    CleatDeployWeb.Endpoint.url() <> ~p"/users/settings/confirm-email/#{token}"
  end
end
