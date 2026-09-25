defmodule CleatDeployWeb.AppLive.Show do
  use CleatDeployWeb, :live_view

  alias CleatDeploy.{Apps, Deployments, Settings}
  alias CleatDeploy.Apps.{App, AppEnvVar, RuntimeControl, RuntimeLogs, RuntimeMemory}
  alias CleatDeploy.Deploy.{Addons, RuntimePackages}
  alias CleatDeployWeb.AppLive.{Layout, NewInstance}

  # Fallback while a deploy is active. Live updates come from PubSub.
  @poll_ms 15_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    app = Apps.get_app!(scope, id)
    runtime_packages = RuntimePackages.resolve(app).packages
    custom_domain_app? = app.slug == "catalogo"
    deploying? = Deployments.deploying?(scope, app)
    setting = Settings.get_setting(scope)

    socket =
      socket
      |> assign(:page_title, app.name)
      |> assign(:active_tab, :apps)
      |> assign(:app, app)
      |> assign(:apps, Apps.list_app_choices(scope))
      |> assign(:webhook_url, webhook_url())
      |> assign(:show_secret?, false)
      |> assign(:show_env_values?, false)
      |> assign(:env_vars, Apps.list_env_vars_for_display(app))
      |> assign(:env_branches, env_branches(app))
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
      |> schedule_poll(deploying?)

    socket =
      if connected?(socket) do
        :ok = Deployments.subscribe(app)
        send(self(), :load_app_memory)
        socket = assign(socket, :addons, App.deploy_addons(app))
        request_addon_status(socket)
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
          |> maybe_load_logs(tab)

        {:noreply, socket}

      %{"id" => id} ->
        {:noreply, push_navigate(socket, to: ~p"/apps/#{id}/deployments")}
    end
  end

  @impl true
  def handle_event("deploy", _params, socket) do
    case Deployments.enqueue(socket.assigns.current_scope, socket.assigns.app, %{
           git_sha: "manual",
           triggered_by: "manual"
         }) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:deploying?, true)
         |> schedule_poll(true)
         |> put_flash(:info, "Deploy queued")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not queue deploy")}
    end
  end

  def handle_event("open_cancel_deploy", _params, socket) do
    {:noreply, assign(socket, :confirming_cancel?, true)}
  end

  def handle_event("close_cancel_deploy", _params, socket) do
    {:noreply, assign(socket, :confirming_cancel?, false)}
  end

  def handle_event("cancel_deploy", _params, socket) do
    socket = assign(socket, :confirming_cancel?, false)

    case Deployments.cancel(socket.assigns.current_scope, socket.assigns.app) do
      {:ok, deployment} ->
        {:noreply,
         socket
         |> refresh_deploying()
         |> put_flash(:info, "Deploy ##{deployment.id} cancelled")}

      {:error, :no_active_deployment} ->
        {:noreply, put_flash(socket, :error, "No deploy queued or running")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not cancel the deploy")}
    end
  end

  def handle_event("toggle_secret", _params, socket) do
    {:noreply, assign(socket, :show_secret?, not socket.assigns.show_secret?)}
  end

  def handle_event("toggle_env_values", _params, socket) do
    {:noreply, assign(socket, :show_env_values?, not socket.assigns.show_env_values?)}
  end

  def handle_event("open_env_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:env_form, to_form(Apps.change_env_var(socket.assigns.app), as: :env))
     |> assign(:editing_env_var?, false)
     |> assign(:env_modal_open?, true)}
  end

  def handle_event("edit_env_var", %{"key" => key, "branch" => branch}, socket) do
    case Enum.find(socket.assigns.env_vars, &(&1.key == key and &1.branch == branch)) do
      nil ->
        {:noreply, put_flash(socket, :error, "#{key} is no longer configured")}

      env_var ->
        form =
          socket.assigns.app
          |> Apps.change_env_var(%{
            key: env_var.key,
            value: env_var.value,
            branch: env_var.branch
          })
          |> to_form(as: :env)

        {:noreply,
         socket
         |> assign(:env_form, form)
         |> assign(:editing_env_var?, true)
         |> assign(:env_modal_open?, true)}
    end
  end

  def handle_event("close_env_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:env_form, to_form(Apps.change_env_var(socket.assigns.app), as: :env))
     |> assign(:editing_env_var?, false)
     |> assign(:env_modal_open?, false)}
  end

  def handle_event("validate_env", %{"env" => params}, socket) do
    form =
      socket.assigns.app
      |> Apps.change_env_var(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :env)

    {:noreply, assign(socket, :env_form, form)}
  end

  def handle_event("save_env_var", %{"env" => params}, socket) do
    changeset =
      socket.assigns.app
      |> Apps.change_env_var(params)
      |> Map.put(:action, :validate)

    if changeset.valid? do
      key = Ecto.Changeset.get_field(changeset, :key)
      value = Ecto.Changeset.get_field(changeset, :value)
      branch = Ecto.Changeset.get_field(changeset, :branch)

      case Apps.put_env_var(socket.assigns.app, key, value, branch) do
        {:ok, _env_var} ->
          {:noreply,
           socket
           |> assign(:env_modal_open?, false)
           |> assign(:editing_env_var?, false)
           |> refresh_env_vars()
           |> put_flash(:info, "#{key} saved for #{branch_label(branch)} — deploy to apply")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not save #{key}")}
      end
    else
      {:noreply, assign(socket, :env_form, to_form(changeset, as: :env))}
    end
  end

  def handle_event("delete_env_var", %{"key" => key, "branch" => branch}, socket) do
    case Apps.delete_env_var(socket.assigns.app, key, branch) do
      :ok ->
        {:noreply,
         socket
         |> assign(:env_modal_open?, false)
         |> assign(:editing_env_var?, false)
         |> refresh_env_vars()
         |> put_flash(:info, "#{key} removed for #{branch_label(branch)}")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "#{key} is not configured for that branch")}
    end
  end

  def handle_event("select_app", %{"app_id" => app_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/apps/#{app_id}/deployments")}
  end

  def handle_event("refresh_logs", _params, socket) do
    {:noreply, request_logs(socket)}
  end

  def handle_event("validate_branch", %{"app" => params}, socket) do
    form =
      socket.assigns.app
      |> Apps.change_branch(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :app)

    {:noreply, assign(socket, :branch_form, form)}
  end

  def handle_event("save_branch", %{"app" => params}, socket) do
    case Apps.update_app(socket.assigns.current_scope, socket.assigns.app, params) do
      {:ok, app} ->
        app = Apps.get_app!(socket.assigns.current_scope, app.id)

        {:noreply,
         socket
         |> assign(:app, app)
         |> assign(:apps, Apps.list_app_choices(socket.assigns.current_scope))
         |> assign(:branch_form, to_form(Apps.change_branch(app), as: :app))
         |> put_flash(:info, "Auto-deploy now listens to #{app.branch}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :branch_form, to_form(changeset, as: :app))}
    end
  end

  def handle_event("toggle_idle_shutdown", _params, socket) do
    target = not socket.assigns.app.idle_shutdown_enabled

    case Apps.update_app_settings(socket.assigns.current_scope, socket.assigns.app, %{
           "idle_shutdown_enabled" => target
         }) do
      {:ok, app} ->
        app = Apps.get_app!(socket.assigns.current_scope, app.id)

        {:noreply,
         socket
         |> assign(:app, app)
         |> assign(:confirming_idle_sleep?, false)
         |> put_flash(:info, idle_shutdown_flash(app))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:confirming_idle_sleep?, false)
         |> put_flash(:error, "Could not update auto sleep")}
    end
  end

  def handle_event("toggle_indexable", _params, socket) do
    target = not socket.assigns.app.indexable

    case Apps.update_app_settings(socket.assigns.current_scope, socket.assigns.app, %{
           "indexable" => target
         }) do
      {:ok, app} ->
        app = Apps.get_app!(socket.assigns.current_scope, app.id)

        {:noreply,
         socket
         |> assign(:app, app)
         |> put_flash(:info, indexable_flash(app))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update indexing")}
    end
  end

  def handle_event("open_idle_sleep", _params, socket) do
    {:noreply, assign(socket, :confirming_idle_sleep?, true)}
  end

  def handle_event("close_idle_sleep", _params, socket) do
    {:noreply, assign(socket, :confirming_idle_sleep?, false)}
  end

  def handle_event("rotate_addon_prompt", %{"addon" => addon}, socket) do
    {:noreply, assign(socket, :rotating_addon, addon)}
  end

  def handle_event("close_rotate_addon", _params, socket) do
    {:noreply, assign(socket, :rotating_addon, nil)}
  end

  def handle_event("rotate_addon", %{"addon" => addon}, socket) do
    {_addons, _credentials} = Addons.rotate(socket.assigns.app, [addon])

    {:noreply,
     socket
     |> assign(:rotating_addon, nil)
     |> put_flash(:info, "New credentials stored — deploy this app to apply them")
     |> request_addon_status()}
  end

  def handle_event("refresh_addon_status", _params, socket) do
    {:noreply, request_addon_status(socket)}
  end

  def handle_event("open_hibernate", _params, socket) do
    {:noreply, assign(socket, :confirming_hibernate?, true)}
  end

  def handle_event("close_hibernate", _params, socket) do
    {:noreply, assign(socket, :confirming_hibernate?, false)}
  end

  def handle_event("hibernate_app", _params, socket) do
    socket = assign(socket, :confirming_hibernate?, false)

    case RuntimeControl.hibernate(socket.assigns.app) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{socket.assigns.app.name} hibernated — no CPU or RAM until it wakes"
         )
         |> refresh_runtime()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not hibernate: #{reason}")}
    end
  end

  def handle_event("wake_app", _params, socket) do
    case RuntimeControl.wake(socket.assigns.app) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "#{socket.assigns.app.name} is starting")
         |> refresh_runtime()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not wake: #{reason}")}
    end
  end

  def handle_event("validate_delete", %{"delete" => params}, socket) do
    confirm = Map.get(params, "confirm", "")

    {:noreply,
     socket
     |> assign(:delete_confirm, confirm)
     |> assign(:delete_form, to_form(%{"confirm" => confirm}, as: :delete))}
  end

  def handle_event("delete_app", %{"delete" => params}, socket) do
    app = socket.assigns.app
    confirm = params |> Map.get("confirm", "") |> String.trim()

    cond do
      socket.assigns.deploying? ->
        {:noreply, put_flash(socket, :error, "Wait for the running deploy to finish")}

      confirm != app.slug ->
        {:noreply, put_flash(socket, :error, "Type #{app.slug} to confirm deletion")}

      true ->
        case Apps.delete_app(socket.assigns.current_scope, app) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "#{app.name} was deleted")
             |> push_navigate(to: ~p"/apps")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not delete #{app.name}")}
        end
    end
  end

  # Instance form events live in the shared module, also used by the
  # deployments page.
  def handle_event(event, params, socket) do
    NewInstance.handle_event(event, params, socket)
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
    {:noreply, refresh_deploying(socket)}
  end

  def handle_info({:deployment_changed, app_id}, socket)
      when app_id == socket.assigns.app.id do
    {:noreply, refresh_deploying(socket)}
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
            <div :if={@app_detail_tab == :domains} id="custom-domain-checklist" class="space-y-3">
              <div class="flex flex-wrap items-center gap-2">
                <h3 class="font-display text-xs font-semibold text-hd-text">Custom tenant domains</h3>
                <span class="rounded border border-hd-orange/40 bg-hd-orange/10 px-2 py-0.5 font-mono text-[9px] text-hd-orange">
                  Solo server · on-demand TLS
                </span>
              </div>
              <p class="text-[11px] leading-relaxed text-hd-muted">
                Tenants point a <span class="font-mono text-hd-text">CNAME</span>
                to <span class="font-mono text-hd-orange">DOMAIN_CNAME_TARGET</span>
                (set to {@app.host}), then verify DNS in the admin panel.
                Caddy issues certificates only after the tenant domain is verified.
              </p>
              <ul class="space-y-1 font-mono text-[10px] text-hd-muted">
                <li>
                  <span class="text-hd-orange">PLATFORM_HOSTS</span>
                  — platform hostnames served directly
                </li>
                <li>
                  <span class="text-hd-orange">DOMAIN_CNAME_TARGET</span>
                  — CNAME anchor for tenant custom domains
                </li>
                <li>
                  <span class="text-hd-orange">PHX_HOST</span> — primary platform host ({@app.host})
                </li>
              </ul>
            </div>

            <div :if={@app_detail_tab == :logs} id="app-runtime-logs" class="space-y-3">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="space-y-0.5">
                  <h3 class="font-display text-xs font-semibold text-hd-text">
                    Runtime logs
                  </h3>
                  <p class="text-[11px] text-hd-muted">
                    Last {RuntimeLogs.line_count()} journal lines from
                    <span class="font-mono text-hd-orange">
                      {log_unit(@app, @runtime_logs)}
                    </span>
                    on {@app.server.name}.
                  </p>
                </div>
                <button
                  id="refresh-app-logs"
                  type="button"
                  phx-click="refresh_logs"
                  phx-disable-with="Reading…"
                  class="paas-btn-secondary text-[10px]"
                >
                  <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
                </button>
              </div>

              <div
                :if={@logs_error}
                class="rounded border border-rose-500/40 bg-rose-500/10 px-3 py-2 font-mono text-[11px] text-rose-400"
              >
                {@logs_error}
              </div>

              <div class="overflow-hidden rounded-md border border-hd-border bg-hd-bg font-mono text-[11px] text-hd-text">
                <div class="flex items-center justify-between border-b border-hd-border bg-hd-aside px-3 py-1.5">
                  <div class="flex items-center gap-1.5">
                    <.icon name="hero-command-line" class="size-3.5 text-hd-orange" />
                    <span class="text-[10px] font-semibold tracking-wider text-hd-muted">
                      SYSTEMD JOURNAL
                    </span>
                  </div>
                  <span :if={@runtime_logs} class="font-mono text-[10px] text-hd-muted">
                    {Calendar.strftime(@runtime_logs.fetched_at, "%Y-%m-%d %H:%M:%S UTC")}
                  </span>
                </div>
                <div
                  id="app-runtime-logs-body"
                  phx-hook=".LogsScroll"
                  class="h-96 overflow-auto p-3 font-mono text-[11px] leading-5"
                >
                  <div
                    :if={is_nil(@runtime_logs) and is_nil(@logs_error)}
                    class="text-hd-muted"
                  >
                    Reading journal…
                  </div>
                  <div
                    :if={@runtime_logs && @runtime_logs.lines == []}
                    class="text-hd-muted"
                  >
                    No journal entries for this unit yet.
                  </div>
                  <div
                    :for={{line, index} <- log_lines(@runtime_logs)}
                    id={"log-line-#{index + 1}"}
                    class="flex items-start"
                  >
                    <span class="sticky left-0 z-10 mr-3 w-8 shrink-0 select-none bg-hd-bg pr-1 text-right tabular-nums text-hd-muted/40">
                      {index + 1}
                    </span>
                    <span class={["min-w-0 whitespace-pre", log_line_class(line)]}>{line}</span>
                  </div>
                  <script :type={Phoenix.LiveView.ColocatedHook} name=".LogsScroll">
                    export default {
                      mounted() { this.el.scrollTop = this.el.scrollHeight },
                      updated() { this.el.scrollTop = this.el.scrollHeight }
                    }
                  </script>
                </div>
              </div>
            </div>

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
                      id={env_var_row_id(env_var)}
                      data-branch={env_var.branch}
                    >
                      <td class="align-top whitespace-nowrap text-[11px] text-hd-muted">
                        {branch_label(env_var.branch)}
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
                          data-confirm={"Remove #{env_var.key} for #{branch_label(env_var.branch)}?"}
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

            <div :if={@app_detail_tab == :runtime} id="runtime-packages" class="space-y-3">
              <div class="space-y-0.5">
                <h3 class="font-display text-xs font-semibold text-hd-text">Runtime packages</h3>
                <p class="text-[11px] text-hd-muted">
                  Installed automatically on every deploy via apt.
                </p>
              </div>
              <div class="flex flex-wrap gap-2">
                <span
                  :for={package <- @runtime_packages}
                  class="rounded border border-hd-border bg-hd-aside px-2 py-0.5 font-mono text-[10px] text-hd-orange"
                >
                  {package}
                </span>
              </div>
            </div>

            <div :if={@app_detail_tab == :webhook} id="app-webhook" class="space-y-5">
              <div class="space-y-3">
                <div class="space-y-0.5">
                  <h3 class="font-display text-xs font-semibold text-hd-text">
                    Deploy branch
                  </h3>
                  <p class="text-[11px] leading-relaxed text-hd-muted">
                    Auto-deploy queues only when GitHub pushes this branch.
                    Other refs are ignored.
                  </p>
                </div>
                <.form
                  for={@branch_form}
                  id="deploy-branch-form"
                  phx-change="validate_branch"
                  phx-submit="save_branch"
                  class="flex flex-col gap-2 sm:flex-row sm:items-end"
                >
                  <div class="min-w-0 flex-1">
                    <.input
                      field={@branch_form[:branch]}
                      id="app-deploy-branch-input"
                      type="text"
                      label="Branch"
                      class="paas-input w-full font-mono"
                      spellcheck="false"
                      autocomplete="off"
                    />
                  </div>
                  <button
                    id="save-deploy-branch"
                    type="submit"
                    class="paas-btn-primary mb-2 shrink-0"
                  >
                    Save branch
                  </button>
                </.form>
              </div>

              <div class="space-y-0.5">
                <h3 class="font-display text-xs font-semibold text-hd-text">
                  GitHub Push webhook URL Credentials
                </h3>
                <p class="text-[11px] text-hd-muted">
                  Configure these properties on GitHub (Repository Settings → Webhooks) to enable instant automatic deploys on push
                </p>
              </div>
              <div class="grid gap-3 md:grid-cols-2">
                <.copy_field id="webhook-url" label="Payload URL" value={@webhook_url} mono />
                <div class="space-y-1">
                  <div class="flex items-center justify-between">
                    <span class="font-mono text-[9px] font-semibold uppercase tracking-wider text-hd-muted">
                      Webhook Secret token
                    </span>
                    <button
                      type="button"
                      phx-click="toggle_secret"
                      class="text-[10px] text-hd-orange hover:underline"
                    >
                      {if @show_secret?, do: "Hide", else: "Reveal"}
                    </button>
                  </div>
                  <.copy_field
                    :if={@show_secret?}
                    id="webhook-secret"
                    label=""
                    value={@app.webhook_secret}
                    mono
                  />
                  <div
                    :if={not @show_secret?}
                    id="webhook-secret-masked"
                    class="rounded border border-hd-border bg-hd-aside px-2.5 py-1.5 font-mono text-xs text-hd-muted/60"
                  >
                    {String.duplicate("•", 32)}
                  </div>
                </div>
              </div>
            </div>

            <div :if={@app_detail_tab == :danger} id="app-danger-zone" class="space-y-4">
              <div class="space-y-0.5">
                <h3 class="font-display text-xs font-semibold text-rose-400">Danger zone</h3>
                <p class="text-[11px] leading-relaxed text-hd-muted">
                  Permanently removes <span class="font-medium text-hd-text">{@app.name}</span>
                  from Cleat — deploy history, env vars, and the GitHub webhook.
                  The unit on {@app.server.name} is stopped and
                  <span class="font-mono text-hd-text">{@app.release_path}</span>
                  is deleted. This cannot be undone.
                </p>
              </div>

              <div class="rounded-lg border border-rose-500/30 bg-rose-500/5 p-4">
                <.form
                  for={@delete_form}
                  id="delete-app-form"
                  phx-change="validate_delete"
                  phx-submit="delete_app"
                  class="space-y-3"
                >
                  <p class="text-[11px] text-hd-muted">
                    Type <span class="font-mono text-hd-text">{@app.slug}</span> to confirm.
                  </p>
                  <input
                    id="delete-app-confirm"
                    type="text"
                    name={@delete_form[:confirm].name}
                    value={@delete_form[:confirm].value}
                    autocomplete="off"
                    spellcheck="false"
                    class="paas-input w-full font-mono"
                    placeholder={@app.slug}
                  />
                  <button
                    id="delete-app-button"
                    type="submit"
                    disabled={String.trim(@delete_confirm) != @app.slug or @deploying?}
                    class="inline-flex items-center justify-center gap-1.5 rounded-md bg-rose-500 px-3 py-1.5 text-xs font-bold text-white transition-colors hover:bg-rose-400 disabled:cursor-not-allowed disabled:opacity-40"
                  >
                    <.icon name="hero-trash" class="size-3.5" /> Delete {@app.name}
                  </button>
                </.form>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp refresh_deploying(socket) do
    deploying? = Deployments.deploying?(socket.assigns.current_scope, socket.assigns.app)

    socket
    |> assign(:deploying?, deploying?)
    |> schedule_poll(deploying?)
  end

  defp schedule_poll(socket, true) do
    Process.send_after(self(), :poll_deployments, @poll_ms)
    socket
  end

  defp schedule_poll(socket, false), do: socket

  defp webhook_url do
    CleatDeployWeb.Endpoint.url() <> "/webhooks/github"
  end

  defp refresh_env_vars(socket) do
    # Re-read the app: the env_vars preloaded in the socket are stale after a
    # write.
    app = Apps.get_app!(socket.assigns.current_scope, socket.assigns.app.id)

    socket
    |> assign(:app, app)
    |> assign(:env_vars, Apps.list_env_vars_for_display(app))
    |> assign(:env_branches, env_branches(app))
  end

  # Branches offered for scoping a variable: the deploy branch plus whatever is
  # already scoped in this app. "All branches" is the empty/default scope.
  defp env_branches(app) do
    app
    |> Apps.list_env_vars_for_display()
    |> Enum.map(& &1.branch)
    |> Kernel.++([app.branch])
    |> Enum.reject(&AppEnvVar.all_branches?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp env_var_row_id(%{key: key, branch: branch}) do
    if AppEnvVar.all_branches?(branch) do
      "env-var-#{key}"
    else
      "env-var-#{key}-#{branch}"
    end
  end

  defp branch_label(branch) do
    if AppEnvVar.all_branches?(branch), do: "All branches", else: branch
  end

  defp idle_shutdown_flash(%{idle_shutdown_enabled: true}),
    do: "Auto sleep on — deploy this app to arm it on the server"

  defp idle_shutdown_flash(_app), do: "Auto sleep off"

  defp indexable_flash(%{indexable: true}),
    do: "Indexing on — deploy this app to apply it on the server"

  defp indexable_flash(_app),
    do: "Indexing off — deploy this app to apply it on the server"

  # Re-reads the systemd state so the status tile and the hibernate button
  # reflect what just happened.
  defp refresh_runtime(socket) do
    send(self(), :load_app_memory)
    socket
  end

  defp maybe_load_logs(socket, :logs) do
    if connected?(socket), do: request_logs(socket), else: socket
  end

  defp maybe_load_logs(socket, _tab), do: socket

  # The addon probe SSHes into the server; only run it when the app declares
  # addons, and let the card show its "checking" state until it answers.
  defp request_addon_status(socket) do
    if socket.assigns.addons == [] do
      socket
    else
      send(self(), :load_addon_status)
      assign(socket, :addon_status, nil)
    end
  end

  # The journal read happens in a task; the template shows its "Reading…" state
  # until the result lands.
  defp request_logs(socket) do
    send(self(), :load_app_logs)
    assign(socket, :runtime_logs, nil)
  end

  defp log_unit(_app, %{unit: unit}), do: unit

  defp log_unit(app, _) do
    app.systemd_unit || Apps.App.default_systemd_unit(app.slug, app.runtime || "phoenix")
  end

  defp log_lines(%{lines: lines}) when is_list(lines),
    do: Enum.with_index(lines)

  defp log_lines(_), do: []

  defp log_line_class(line) do
    down = String.downcase(line)

    cond do
      String.contains?(down, "error") or String.contains?(down, "fail") ->
        "text-rose-400"

      String.contains?(down, "warn") ->
        "text-hd-orange"

      true ->
        "text-hd-text"
    end
  end
end
