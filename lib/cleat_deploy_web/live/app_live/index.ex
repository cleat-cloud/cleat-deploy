defmodule CleatDeployWeb.AppLive.Index do
  use CleatDeployWeb, :live_view

  alias CleatDeploy.{Apps, Github, Servers}
  alias CleatDeploy.Apps.{App, Provisioning, RuntimeMemory}

  @impl true
  def mount(_params, _session, socket) do
    apps = Apps.list_apps(socket.assigns.current_scope)

    socket =
      socket
      |> assign(:page_title, "Apps")
      |> assign(:active_tab, :apps)
      |> assign(:servers, Servers.list_servers(socket.assigns.current_scope))
      |> assign(:apps_list, apps)
      |> assign(:app_memory, %{})
      |> assign(:apps_query, "")
      |> assign(:apps_runtime, :all)
      |> assign(:apps_sort, :name)
      |> assign(:apps_sort_dir, :asc)
      |> restream_apps(apps, %{})

    socket =
      if connected?(socket) do
        send(self(), :load_app_memory)
        socket
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    repos = Github.list_repos()

    socket
    |> assign(:page_title, "New app")
    |> assign(:app, %App{})
    |> assign(:github_repos, repos)
    |> assign(:repo_search, "")
    |> assign(:repo_picker_open?, false)
    |> assign(:show_advanced?, false)
    |> assign(:form, to_form(Apps.change_app(%App{})))
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Apps")
    |> assign(:app, nil)
    |> assign(:form, nil)
    |> assign(:github_repos, [])
    |> assign(:repo_search, "")
    |> assign(:repo_picker_open?, false)
    |> assign(:show_advanced?, false)
  end

  @impl true
  def handle_event("validate", %{"app" => app_params}, socket) do
    {:noreply, apply_form_params(socket, app_params)}
  end

  def handle_event("search_repos", %{"repo_search" => query}, socket) do
    {:noreply,
     socket
     |> assign(:repo_search, query)
     |> assign(:repo_picker_open?, true)}
  end

  def handle_event("open_repo_picker", _params, socket) do
    {:noreply, assign(socket, :repo_picker_open?, true)}
  end

  def handle_event("close_repo_picker", _params, socket) do
    {:noreply, assign(socket, :repo_picker_open?, false)}
  end

  def handle_event("pick_repo", %{"repo" => repo}, socket) do
    {:noreply,
     socket
     |> assign(:repo_search, repo)
     |> assign(:repo_picker_open?, false)
     |> apply_form_params(%{"github_repo" => repo})}
  end

  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, assign(socket, :show_advanced?, not socket.assigns.show_advanced?)}
  end

  def handle_event("filter_apps", params, socket) do
    query = params["query"] || params["apps_query"] || ""

    {:noreply,
     socket
     |> assign(:apps_query, query)
     |> restream_apps()}
  end

  def handle_event("filter_runtime", %{"runtime" => runtime}, socket) do
    runtime =
      case runtime do
        "golang" -> :golang
        "node" -> :node
        "rails" -> :rails
        "phoenix" -> :phoenix
        _ -> :all
      end

    {:noreply,
     socket
     |> assign(:apps_runtime, runtime)
     |> restream_apps()}
  end

  def handle_event("sort_apps", %{"by" => field}, socket) do
    field = sort_field(field)

    {sort, dir} =
      if socket.assigns.apps_sort == field do
        {field, toggle_dir(socket.assigns.apps_sort_dir)}
      else
        {field, :asc}
      end

    {:noreply,
     socket
     |> assign(:apps_sort, sort)
     |> assign(:apps_sort_dir, dir)
     |> restream_apps()}
  end

  def handle_event("save", %{"app" => app_params}, socket) do
    app_params =
      app_params
      |> maybe_put_advanced(socket.assigns.show_advanced?)
      |> then(&Provisioning.apply_preset(&1, socket.assigns.servers))

    case Apps.create_app(socket.assigns.current_scope, app_params) do
      {:ok, app, webhook_status} ->
        app = Apps.get_app!(socket.assigns.current_scope, app.id)

        apps_list = [app | socket.assigns.apps_list]

        {:noreply,
         socket
         |> assign(:apps_list, apps_list)
         |> restream_apps()
         |> assign(:app_count, socket.assigns.app_count + 1)
         |> put_flash(:info, app_registered_message(webhook_status))
         |> push_navigate(to: ~p"/apps/#{app.id}/deployments")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  @impl true
  def handle_info(:load_app_memory, socket) do
    memory = RuntimeMemory.for_apps(socket.assigns.apps_list)

    {:noreply,
     socket
     |> assign(:app_memory, memory)
     |> restream_apps()}
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
      <div class="space-y-4">
        <div
          :if={@servers == []}
          class="flex items-center gap-3 rounded-md border border-hd-orange/30 bg-hd-card px-4 py-3 text-sm text-hd-orange"
        >
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>Add a server before registering an app.</span>
        </div>

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
                      {"Ruby on Rails", "rails"}
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

        <div class="overflow-hidden rounded-md border border-hd-border bg-hd-card">
          <div class="flex items-center justify-between border-b border-hd-border bg-hd-aside px-4 py-2.5">
            <div class="space-y-0.5">
              <h3 class="font-display text-xs font-semibold text-hd-text">
                Registered Phoenix Applications
              </h3>
              <p class="text-[11px] text-hd-muted">
                Live directory mapping GitHub repositories to systemd processes
              </p>
            </div>
            <.link
              :if={@servers != []}
              navigate={~p"/apps/new"}
              class="flex items-center gap-1 font-mono text-xs font-bold text-hd-orange hover:text-hd-orange-dark"
            >
              <.icon name="hero-plus" class="size-3.5" /> Register App
            </.link>
          </div>

          <div class="flex flex-col gap-3 border-b border-hd-border bg-hd-aside/40 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
            <.form
              for={to_form(%{"query" => @apps_query})}
              id="apps-filter"
              phx-change="filter_apps"
              class="min-w-0 flex-1"
            >
              <label class="relative block max-w-md">
                <span class="sr-only">Filter applications</span>
                <.icon
                  name="hero-magnifying-glass"
                  class="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-hd-muted"
                />
                <input
                  type="search"
                  name="query"
                  id="apps-query"
                  value={@apps_query}
                  phx-debounce="150"
                  placeholder="Filter by name, host, language, or server"
                  class="paas-input w-full pl-9"
                />
              </label>
            </.form>
            <div class="flex flex-wrap items-center gap-1.5">
              <.runtime_filter_chip id="apps-filter-all" runtime={:all} current={@apps_runtime}>
                All
              </.runtime_filter_chip>
              <.runtime_filter_chip
                id="apps-filter-phoenix"
                runtime={:phoenix}
                current={@apps_runtime}
              >
                Elixir
              </.runtime_filter_chip>
              <.runtime_filter_chip
                id="apps-filter-golang"
                runtime={:golang}
                current={@apps_runtime}
              >
                Go
              </.runtime_filter_chip>
              <.runtime_filter_chip
                id="apps-filter-node"
                runtime={:node}
                current={@apps_runtime}
              >
                JS
              </.runtime_filter_chip>
              <.runtime_filter_chip
                id="apps-filter-rails"
                runtime={:rails}
                current={@apps_runtime}
              >
                Ruby
              </.runtime_filter_chip>
            </div>
          </div>

          <div class="overflow-x-auto">
            <table id="apps-table" class="paas-table w-full text-left">
              <thead>
                <tr>
                  <.sort_header field={:name} label="Name" sort={@apps_sort} dir={@apps_sort_dir} />
                  <.sort_header field={:host} label="Host" sort={@apps_sort} dir={@apps_sort_dir} />
                  <.sort_header
                    field={:language}
                    label="Main language"
                    sort={@apps_sort}
                    dir={@apps_sort_dir}
                  />
                  <.sort_header field={:ram} label="RAM" sort={@apps_sort} dir={@apps_sort_dir} />
                  <.sort_header field={:cpu} label="CPU" sort={@apps_sort} dir={@apps_sort_dir} />
                  <.sort_header field={:disk} label="Disk" sort={@apps_sort} dir={@apps_sort_dir} />
                  <.sort_header
                    field={:server}
                    label="Server"
                    sort={@apps_sort}
                    dir={@apps_sort_dir}
                  />
                  <th class="text-right">Action</th>
                </tr>
              </thead>
              <tbody id="apps-list" phx-update="stream">
                <tr :if={@apps_list == []} id="apps-empty">
                  <td colspan="8" class="py-8 text-center text-hd-muted">
                    <div class="space-y-3">
                      <p class="font-mono text-xs">No applications configured.</p>
                      <.link
                        :if={@servers != []}
                        navigate={~p"/apps/new"}
                        class="paas-btn-primary inline-flex"
                      >
                        Register App
                      </.link>
                    </div>
                  </td>
                </tr>
                <tr
                  :if={@apps_list != [] and @apps_visible_count == 0}
                  id="apps-filter-empty"
                >
                  <td colspan="8" class="py-8 text-center text-hd-muted">
                    <p class="font-mono text-xs">No applications match this filter.</p>
                  </td>
                </tr>
                <tr :for={{id, app} <- @streams.apps} id={id}>
                  <td>
                    <.link
                      navigate={~p"/apps/#{app.id}/deployments"}
                      class="font-medium text-hd-orange hover:text-hd-orange-dark"
                    >
                      {app.name}
                    </.link>
                  </td>
                  <td>
                    <.link
                      href={"https://#{app.host}"}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="font-mono text-sm text-hd-orange hover:text-hd-orange-dark hover:underline"
                    >
                      {app.host}
                    </.link>
                  </td>
                  <td>
                    <.language_badge app={app} />
                  </td>
                  <td>
                    <.ram_cell app={app} memory={@app_memory[app.id]} />
                  </td>
                  <td>
                    <.cpu_cell app={app} memory={@app_memory[app.id]} />
                  </td>
                  <td>
                    <.disk_cell app={app} memory={@app_memory[app.id]} />
                  </td>
                  <td>{app.server.name}</td>
                  <td class="text-right">
                    <.link
                      navigate={~p"/apps/#{app.id}/deployments"}
                      class="paas-btn-secondary text-[10px]"
                    >
                      <.icon name="hero-rocket-launch" class="size-3" /> Deploy
                    </.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :include_server_id?, :boolean, default: true

  defp hidden_provision_fields(assigns) do
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

  defp preview_item(assigns) do
    ~H"""
    <div class="min-w-0">
      <dt class="font-mono text-[9px] uppercase tracking-wider text-hd-muted">{@label}</dt>
      <dd class={["truncate text-xs font-medium text-hd-text", @mono && "font-mono"]}>
        {@value || "—"}
      </dd>
    </div>
    """
  end

  defp repo_selected?(form) do
    case form[:github_repo].value do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp advanced_enabled?(params, current?) do
    param = Map.get(params, "advanced") || Map.get(params, :advanced)
    param in ["true", "on", true] || current?
  end

  defp maybe_put_advanced(params, true), do: Map.put(params, "advanced", "true")
  defp maybe_put_advanced(params, false), do: params

  defp apply_form_params(socket, app_params) do
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

  defp server_options(servers) do
    Enum.map(servers, fn server -> {server.name, server.id} end)
  end

  defp server_label(servers, server_id) do
    servers
    |> Enum.find_value(fn server ->
      if to_string(server.id) == to_string(server_id), do: server.name
    end)
  end

  defp app_registered_message(:synced),
    do: "App registered — GitHub webhook connected for automatic deploys"

  defp app_registered_message(:no_token),
    do: "App registered — set GITHUB_TOKEN on the panel to auto-configure webhooks"

  defp app_registered_message({:error, message}),
    do: "App registered — webhook not configured (#{message})"

  defp restream_apps(socket) do
    restream_apps(socket, socket.assigns.apps_list, socket.assigns.app_memory)
  end

  defp restream_apps(socket, apps, memory) do
    visible = visible_apps(apps, socket, memory)

    socket
    |> assign(:apps_visible_count, length(visible))
    |> stream(:apps, visible, reset: true)
  end

  defp visible_apps(apps, socket, memory) do
    apps
    |> Enum.filter(&matches_runtime?(&1, socket.assigns.apps_runtime))
    |> Enum.filter(&matches_query?(&1, socket.assigns.apps_query))
    |> sort_apps(socket.assigns.apps_sort, socket.assigns.apps_sort_dir, memory)
  end

  defp matches_runtime?(_app, :all), do: true
  defp matches_runtime?(%App{runtime: "golang"}, :golang), do: true
  defp matches_runtime?(%App{runtime: "node"}, :node), do: true
  defp matches_runtime?(%App{runtime: "rails"}, :rails), do: true

  defp matches_runtime?(%App{runtime: runtime}, :phoenix)
       when runtime not in ["golang", "node", "rails"],
       do: true

  defp matches_runtime?(_app, _runtime), do: false

  defp matches_query?(_app, query) when query in [nil, ""], do: true

  defp matches_query?(app, query) do
    needle = query |> to_string() |> String.downcase() |> String.trim()

    [app.name, app.host, app.slug, App.main_language(app), app.server && app.server.name]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(fn value -> String.contains?(String.downcase(value), needle) end)
  end

  defp sort_apps(apps, field, dir, memory) do
    {present, missing} = Enum.split_with(apps, &(sort_value(&1, field, memory) != :missing))

    sorted = Enum.sort_by(present, &sort_value(&1, field, memory))
    sorted = if dir == :desc, do: Enum.reverse(sorted), else: sorted
    sorted ++ missing
  end

  defp sort_value(app, :name, _memory), do: String.downcase(app.name || "")
  defp sort_value(app, :host, _memory), do: String.downcase(app.host || "")
  defp sort_value(app, :language, _memory), do: App.main_language(app)

  defp sort_value(app, :server, _memory),
    do: String.downcase((app.server && app.server.name) || "")

  defp sort_value(app, :ram, memory), do: metric(memory, app.id, :bytes)
  defp sort_value(app, :cpu, memory), do: metric(memory, app.id, :cpu_pct)
  defp sort_value(app, :disk, memory), do: metric(memory, app.id, :disk_bytes)
  defp sort_value(app, _field, _memory), do: String.downcase(app.name || "")

  defp metric(memory, app_id, key) do
    case memory[app_id] do
      %{^key => value} when is_number(value) -> value
      _ -> :missing
    end
  end

  defp sort_field("host"), do: :host
  defp sort_field("language"), do: :language
  defp sort_field("ram"), do: :ram
  defp sort_field("cpu"), do: :cpu
  defp sort_field("disk"), do: :disk
  defp sort_field("server"), do: :server
  defp sort_field(_), do: :name

  defp toggle_dir(:asc), do: :desc
  defp toggle_dir(_dir), do: :asc

  attr :id, :string, required: true
  attr :runtime, :atom, required: true
  attr :current, :atom, required: true
  slot :inner_block, required: true

  defp runtime_filter_chip(assigns) do
    active? = assigns.runtime == assigns.current
    assigns = assign(assigns, :active?, active?)

    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="filter_runtime"
      phx-value-runtime={@runtime}
      class={[
        "rounded-md border px-2.5 py-1 font-mono text-[10px] font-semibold uppercase tracking-wide transition-colors",
        @active? && "border-hd-orange/50 bg-hd-orange/10 text-hd-orange",
        not @active? &&
          "border-hd-border bg-hd-card text-hd-muted hover:border-hd-orange/40 hover:text-hd-text"
      ]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :sort, :atom, required: true
  attr :dir, :atom, required: true

  defp sort_header(assigns) do
    active? = assigns.sort == assigns.field
    assigns = assign(assigns, :active?, active?)

    ~H"""
    <th>
      <button
        id={"sort-apps-#{@field}"}
        type="button"
        phx-click="sort_apps"
        phx-value-by={@field}
        class={[
          "inline-flex items-center gap-1 uppercase transition-colors",
          @active? && "text-hd-text",
          not @active? && "text-hd-muted hover:text-hd-text"
        ]}
      >
        {@label}
        <.icon
          :if={@active?}
          name={if @dir == :asc, do: "hero-chevron-up", else: "hero-chevron-down"}
          class="size-3"
        />
      </button>
    </th>
    """
  end
end
