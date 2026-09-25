defmodule CleatDeployWeb.AppLive.Show do
  use CleatDeployWeb, :live_view

  alias CleatDeploy.{Apps, Deployments, Settings}
  alias CleatDeploy.Apps.{App, RuntimeLogs, RuntimeMemory}
  alias CleatDeploy.Deploy.{Addons, RuntimePackages}
  alias CleatDeployWeb.AppLive.{Layout, NewInstance}
  alias CleatDeployWeb.AppLive.Show.{Deploy, Env, Runtime, Tabs}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    app = Apps.get_app!(scope, id)
    runtime_packages = RuntimePackages.resolve(app).packages
    custom_domain_app? = App.custom_domain?(app)
    deploying? = Deployments.deploying?(scope, app)
    setting = Settings.get_setting(scope)

    socket =
      socket
      |> assign(:page_title, app.name)
      |> assign(:active_tab, :apps)
      |> assign(:app, app)
      |> assign(:apps, Apps.list_app_choices(scope))
      |> assign(:webhook_url, Deploy.webhook_url())
      |> assign(:show_secret?, false)
      |> assign(:show_env_values?, false)
      |> assign(:env_vars, Apps.list_env_vars_for_display(app))
      |> assign(:env_branches, Env.env_branches(app))
      |> assign(:env_form, to_form(Apps.change_env_var(app), as: :env))
      |> assign(:env_modal_open?, false)
      |> assign(:editing_env_var?, false)
      |> assign(:env_file, Apps.App.deploy_config(app).env_file)
      |> assign(:runtime_packages, runtime_packages)
      |> assign(:custom_domain_app?, custom_domain_app?)
      |> assign(:detail_tabs, Layout.detail_tabs(custom_domain_app?, runtime_packages))
      |> assign(:app_detail_tab, :environment)
      |> assign(:runtime_logs, nil)
      |> assign(:logs_error, nil)
      |> assign(:app_memory, nil)
      |> assign(:memory_ref, nil)
      |> assign(:logs_ref, nil)
      |> assign(:addons, [])
      |> assign(:addon_status, nil)
      |> assign(:addon_status_ref, nil)
      |> assign(:rotating_addon, nil)
      |> assign(:delete_confirm, "")
      |> assign(:delete_form, to_form(%{"confirm" => ""}, as: :delete))
      |> NewInstance.assigns()
      |> assign(:branch_form, to_form(Apps.change_branch(app), as: :app))
      |> assign(:idle_shutdown_global?, setting.idle_shutdown_enabled)
      |> assign(:idle_shutdown_minutes, setting.idle_shutdown_minutes)
      |> assign(:deploying?, deploying?)
      |> assign(:confirming_cancel?, false)
      |> assign(:confirming_hibernate?, false)
      |> assign(:confirming_idle_sleep?, false)
      |> Deploy.schedule_poll(deploying?)

    socket =
      if connected?(socket) do
        :ok = Deployments.subscribe(app)
        send(self(), :load_app_memory)
        socket = assign(socket, :addons, App.deploy_addons(app))
        Runtime.request_addon_status(socket)
      else
        assign(socket, :addons, App.deploy_addons(app))
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case params do
      %{"id" => _id, "tab" => tab} ->
        tab = Layout.parse_detail_tab(tab)

        socket =
          socket
          |> assign(:app_detail_tab, tab)
          |> Runtime.maybe_load_logs(tab)

        {:noreply, socket}

      %{"id" => id} ->
        {:noreply, push_navigate(socket, to: ~p"/apps/#{id}/deployments")}
    end
  end

  @env_events ~w(toggle_secret toggle_env_values open_env_modal edit_env_var close_env_modal validate_env save_env_var delete_env_var)
  @deploy_events ~w(deploy open_cancel_deploy close_cancel_deploy cancel_deploy)

  @impl true
  def handle_event(event, params, socket) when event in @env_events do
    Env.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) when event in @deploy_events do
    Deploy.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) do
    case Runtime.handle_event(event, params, socket) do
      :passthrough -> NewInstance.handle_event(event, params, socket)
      other -> other
    end
  end

  @impl true
  def handle_info(:load_app_memory, socket) do
    ref = make_ref()
    {:ok, _pid} = RuntimeMemory.probe_async(self(), ref, socket.assigns.app)

    {:noreply, assign(socket, :memory_ref, ref)}
  end

  def handle_info({:app_memory, ref, memory}, socket) do
    if ref == socket.assigns.memory_ref do
      {:noreply, assign(socket, :app_memory, memory)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:load_app_logs, socket) do
    ref = make_ref()
    {:ok, _pid} = RuntimeLogs.probe_async(self(), ref, socket.assigns.app)

    {:noreply, assign(socket, :logs_ref, ref)}
  end

  def handle_info({:app_logs, ref, result}, socket) do
    if ref == socket.assigns.logs_ref do
      case result do
        {:ok, logs} ->
          {:noreply, assign(socket, runtime_logs: logs, logs_error: nil)}

        {:error, message} ->
          {:noreply, assign(socket, runtime_logs: nil, logs_error: message)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(:load_addon_status, socket) do
    ref = make_ref()
    {:ok, _pid} = Addons.probe_async(self(), ref, socket.assigns.app, socket.assigns.addons)

    {:noreply, assign(socket, :addon_status_ref, ref)}
  end

  def handle_info({:addon_status, ref, result}, socket) do
    if ref == socket.assigns.addon_status_ref do
      case result do
        {:ok, status} -> {:noreply, assign(socket, :addon_status, status)}
        {:error, message} -> {:noreply, assign(socket, :addon_status, %{error: message})}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(:poll_deployments, socket) do
    {:noreply, Deploy.refresh_deploying(socket)}
  end

  def handle_info({:deployment_changed, app_id}, socket)
      when app_id == socket.assigns.app.id do
    {:noreply, Deploy.refresh_deploying(socket)}
  end

  def handle_info({:deployment_changed, _app_id}, socket), do: {:noreply, socket}

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
        <Layout.shell_header app={@app} apps={@apps} instances={@instances} />
        <Layout.shell_hero
          app={@app}
          deploying?={@deploying?}
          confirming_cancel?={@confirming_cancel?}
          confirming_hibernate?={@confirming_hibernate?}
          confirming_idle_sleep?={@confirming_idle_sleep?}
          confirming_new_instance?={@confirming_new_instance?}
          instance_form={@instance_form}
          instance_defaults={@instance_defaults}
          instance_errors={@instance_errors}
          global_enabled?={@idle_shutdown_global?}
          minutes={@idle_shutdown_minutes}
          memory={@app_memory}
        />
        <Layout.shell_info_tiles app={@app} memory={@app_memory} />

        <Layout.addons_card
          :if={@addons != []}
          app={@app}
          addons={@addons}
          status={@addon_status}
        />

        <Layout.rotate_addon_modal :if={@rotating_addon} addon={@rotating_addon} />

        <div id="app-detail-tabs" class="paas-card overflow-hidden">
          <Layout.tab_bar app={@app} active_tab={@app_detail_tab} detail_tabs={@detail_tabs} />

          <div class="p-4">
            <Tabs.panel {assigns} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
