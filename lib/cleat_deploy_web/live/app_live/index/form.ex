defmodule CleatDeployWeb.AppLive.Index.Form do
  @moduledoc false
  use CleatDeployWeb, :html

  alias CleatDeploy.{Apps}
  alias CleatDeploy.Apps.{App, Provisioning}

  def register_form(assigns) do
    ~H"""
    <div :if={@live_action == :new} class="paas-card">
      <div class="space-y-4 p-4">
        <div class="space-y-1">
          <h3 class="font-display text-sm font-semibold text-hd-text">
            Register application
          </h3>
          <p class="text-xs text-hd-muted">
            Pick a GitHub repository — Phoenix and Go (Cais) apps are detected automatically.
          </p>
        </div>

        <.form for={@form} id="app-form" phx-change="validate" phx-submit="save" class="space-y-4">
          <.input
            :if={@github_repos == []}
            field={@form[:github_repo]}
            type="text"
            label="GitHub repo (owner/name)"
            placeholder="puppe1990/my-phoenix-app"
            required
          />
          <.github_repo_picker
            :if={@github_repos != []}
            field={@form[:github_repo]}
            repos={@github_repos}
            repo_search={@repo_search}
            open?={@repo_picker_open?}
          />

          <div
            :if={repo_selected?(@form)}
            id="app-provision-preview"
            class="rounded-md border border-hd-border bg-hd-aside p-3"
          >
            <p class="font-mono text-[10px] font-semibold uppercase tracking-wider text-hd-muted">
              Auto-configured profile
            </p>
            <dl class="mt-2 grid gap-2 sm:grid-cols-2">
              <.preview_item label="Name" value={@form[:name].value} />
              <.preview_item label="Slug" value={@form[:slug].value} mono />
              <.preview_item label="Host" value={@form[:host].value} mono />
              <.preview_item label="Branch" value={@form[:branch].value} mono />
              <.preview_item
                label="Server"
                value={server_label(@servers, @form[:server_id].value)}
              />
              <.preview_item label="Runtime" value={@form[:runtime].value || "phoenix"} mono />
              <.preview_item label="Systemd unit" value={@form[:systemd_unit].value} mono />
              <.preview_item label="Release path" value={@form[:release_path].value} mono />
            </dl>
            <p class="mt-2 text-[11px] text-hd-muted">
              Push webhook is provisioned on save. Runtime packages can come from
              <span class="font-mono">.cleat_deploy/runtime-packages</span>
              in the repo.
            </p>
          </div>

          <div
            :if={@github_repos != [] and not repo_selected?(@form)}
            class="text-xs text-hd-muted"
          >
            Repositories from your GitHub token. Search and pick one to preview the deploy profile.
          </div>

          <.hidden_provision_fields
            :if={repo_selected?(@form) and not @show_advanced?}
            form={@form}
            include_server_id?={length(@servers) <= 1}
          />

          <div
            :if={@servers != [] and length(@servers) > 1 and repo_selected?(@form)}
            class="max-w-md"
          >
            <.input
              field={@form[:server_id]}
              type="select"
              label="Target server"
              options={server_options(@servers)}
            />
          </div>

          <div
            :if={@show_advanced?}
            id="app-advanced-fields"
            class="space-y-4 border-t border-hd-border pt-4"
          >
            <p class="font-mono text-[10px] font-semibold uppercase tracking-wider text-hd-muted">
              Advanced overrides
            </p>
            <div class="grid gap-4 sm:grid-cols-2">
              <.input field={@form[:name]} type="text" label="Name" required />
              <.input field={@form[:slug]} type="text" label="Slug" required />
              <.input field={@form[:host]} type="text" label="Host" required />
              <.input field={@form[:branch]} type="text" label="Branch" />
              <.input
                :if={length(@servers) > 1}
                field={@form[:server_id]}
                type="select"
                label="Server"
                options={server_options(@servers)}
              />
              <.input
                field={@form[:runtime]}
                type="select"
                label="Runtime"
                options={[
                  {"Phoenix / Elixir", "phoenix"},
                  {"Go / Cais", "golang"},
                  {"Node / Next.js / TanStack Start", "node"},
                  {"Ruby on Rails", "rails"},
                  {"Rust / Loco", "rust"},
                  {"Gleam", "gleam"}
                ]}
              />
              <.input
                field={@form[:systemd_unit]}
                type="text"
                label="Systemd unit"
                placeholder="phx-my-app"
              />
              <.input
                field={@form[:release_path]}
                type="text"
                label="Release path"
                placeholder="/opt/my_app"
              />
            </div>
            <.input
              field={@form[:runtime_packages_text]}
              type="textarea"
              label="Runtime packages (apt)"
              placeholder="zip\nffmpeg\nimagemagick"
              rows="4"
            />
          </div>

          <input
            :if={@show_advanced?}
            type="hidden"
            name="app[advanced]"
            value="true"
          />

          <div class="flex flex-wrap items-center gap-2">
            <button
              :if={repo_selected?(@form)}
              type="submit"
              id="save-app-button"
              class="paas-btn-primary"
            >
              Register & connect webhook
            </button>
            <button
              :if={repo_selected?(@form)}
              type="button"
              phx-click="toggle_advanced"
              class="paas-btn-secondary"
            >
              {if @show_advanced?, do: "Hide advanced", else: "Customize"}
            </button>
            <.link navigate={~p"/apps"} class="paas-btn-secondary">Cancel</.link>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :include_server_id?, :boolean, default: true

  def hidden_provision_fields(assigns) do
    ~H"""
    <input type="hidden" name="app[name]" value={@form[:name].value} />
    <input type="hidden" name="app[slug]" value={@form[:slug].value} />
    <input type="hidden" name="app[host]" value={@form[:host].value} />
    <input type="hidden" name="app[branch]" value={@form[:branch].value} />
    <input
      :if={@include_server_id?}
      type="hidden"
      name="app[server_id]"
      value={@form[:server_id].value}
    />
    <input type="hidden" name="app[runtime]" value={@form[:runtime].value || "phoenix"} />
    <input type="hidden" name="app[systemd_unit]" value={@form[:systemd_unit].value} />
    <input type="hidden" name="app[release_path]" value={@form[:release_path].value} />
    <input
      :if={@form[:runtime_packages_text].value}
      type="hidden"
      name="app[runtime_packages_text]"
      value={@form[:runtime_packages_text].value}
    />
    """
  end

  attr :label, :string, required: true
  attr :value, :string, default: nil
  attr :mono, :boolean, default: false

  def preview_item(assigns) do
    ~H"""
    <div class="min-w-0">
      <dt class="font-mono text-[9px] uppercase tracking-wider text-hd-muted">{@label}</dt>
      <dd class={["truncate text-xs font-medium text-hd-text", @mono && "font-mono"]}>
        {@value || "—"}
      </dd>
    </div>
    """
  end

  def repo_selected?(form) do
    case form[:github_repo].value do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  def advanced_enabled?(params, current?) do
    param = Map.get(params, "advanced") || Map.get(params, :advanced)
    param in ["true", "on", true] || current?
  end

  def maybe_put_advanced(params, true), do: Map.put(params, "advanced", "true")
  def maybe_put_advanced(params, false), do: params

  def apply_form_params(socket, app_params) do
    app_params =
      app_params
      |> maybe_put_advanced(socket.assigns.show_advanced?)
      |> then(&Provisioning.apply_preset(&1, socket.assigns.servers))

    show_advanced? = advanced_enabled?(app_params, socket.assigns.show_advanced?)

    changeset =
      %App{}
      |> Apps.change_app(app_params)
      |> Map.put(:action, :validate)

    socket
    |> assign(:show_advanced?, show_advanced?)
    |> assign(:form, to_form(changeset))
  end

  def server_options(servers) do
    Enum.map(servers, fn server -> {server.name, server.id} end)
  end

  def server_label(servers, server_id) do
    servers
    |> Enum.find_value(fn server ->
      if to_string(server.id) == to_string(server_id), do: server.name
    end)
  end

  def app_registered_message(:synced),
    do: "App registered — GitHub webhook connected for automatic deploys"

  def app_registered_message(:no_token),
    do: "App registered — set GITHUB_TOKEN on the panel to auto-configure webhooks"

  def app_registered_message({:error, message}),
    do: "App registered — webhook not configured (#{message})"
end
