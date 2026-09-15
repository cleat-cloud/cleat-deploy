defmodule CleatDeployWeb.AppLive.Show do
  use CleatDeployWeb, :live_view

  alias CleatDeploy.{Apps, Deployments}
  alias CleatDeploy.Apps.{RuntimeLogs, RuntimeMemory}
  alias CleatDeploy.Deploy.RuntimePackages
  alias CleatDeployWeb.AppLive.Layout

  @poll_ms 1_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    app = Apps.get_app!(scope, id)
    runtime_packages = RuntimePackages.resolve(app).packages
    custom_domain_app? = app.slug == "catalogo"
    deploying? = Deployments.deploying?(scope, app)

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
      |> assign(:env_file, Apps.App.deploy_config(app).env_file)
      |> assign(:runtime_packages, runtime_packages)
      |> assign(:custom_domain_app?, custom_domain_app?)
      |> assign(:detail_tabs, Layout.detail_tabs(custom_domain_app?, runtime_packages))
      |> assign(:app_detail_tab, :environment)
      |> assign(:runtime_logs, nil)
      |> assign(:logs_error, nil)
      |> assign(:app_memory, nil)
      |> assign(:delete_confirm, "")
      |> assign(:delete_form, to_form(%{"confirm" => ""}, as: :delete))
      |> assign(:branch_form, to_form(Apps.change_branch(app), as: :app))
      |> assign(:deploying?, deploying?)
      |> assign(:confirming_cancel?, false)
      |> schedule_poll(deploying?)

    socket =
      if connected?(socket) do
        :ok = Deployments.subscribe(app)
        send(self(), :load_app_memory)
        socket
      else
        socket
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

  def handle_event("select_app", %{"app_id" => app_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/apps/#{app_id}/deployments")}
  end

  def handle_event("refresh_logs", _params, socket) do
    {:noreply, load_logs(socket)}
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
        _ = CleatDeploy.Deploy.Teardown.run(app)

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

  @impl true
  def handle_info(:load_app_memory, socket) do
    {:noreply, assign(socket, :app_memory, RuntimeMemory.for_app(socket.assigns.app))}
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
        <Layout.shell_header app={@app} apps={@apps} />
        <Layout.shell_hero
          app={@app}
          deploying?={@deploying?}
          confirming_cancel?={@confirming_cancel?}
        />
        <Layout.shell_info_tiles app={@app} memory={@app_memory} />

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
                    on every deploy. <span class="text-hd-text">PHX_HOST</span>
                    is always injected from the app host ({@app.host}).
                  </p>
                </div>
                <button
                  :if={Enum.any?(@env_vars, & &1.sensitive?)}
                  type="button"
                  phx-click="toggle_env_values"
                  class="shrink-0 text-[10px] text-hd-orange hover:underline"
                >
                  {if @show_env_values?, do: "Hide secrets", else: "Reveal secrets"}
                </button>
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
                      <th>Key</th>
                      <th>Value</th>
                    </tr>
                  </thead>
                  <tbody id="env-vars-list">
                    <tr :for={env_var <- @env_vars} id={"env-var-#{env_var.key}"}>
                      <td class="align-top text-[11px] text-hd-orange">{env_var.key}</td>
                      <td class="max-w-0">
                        <span class="block truncate text-[11px] text-hd-text">
                          {Apps.display_env_value(env_var.key, env_var.value, @show_env_values?)}
                        </span>
                      </td>
                    </tr>
                  </tbody>
                </table>
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

  defp maybe_load_logs(socket, :logs) do
    if connected?(socket), do: load_logs(socket), else: socket
  end

  defp maybe_load_logs(socket, _tab), do: socket

  defp load_logs(socket) do
    case RuntimeLogs.fetch(socket.assigns.app) do
      {:ok, result} ->
        socket
        |> assign(:runtime_logs, result)
        |> assign(:logs_error, nil)

      {:error, message} ->
        socket
        |> assign(:runtime_logs, nil)
        |> assign(:logs_error, message)
    end
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
