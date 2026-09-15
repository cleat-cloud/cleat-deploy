defmodule CleatDeployWeb.AppLive.Deployments do
  use CleatDeployWeb, :live_view

  alias CleatDeploy.{Apps, Deployments}
  alias CleatDeploy.Apps.RuntimeMemory
  alias CleatDeploy.Deploy.RuntimePackages
  alias CleatDeployWeb.AppLive.Layout

  @poll_ms 1_000

  @impl true
  def mount(%{"app_id" => app_id}, _session, socket) do
    scope = socket.assigns.current_scope
    app = Apps.get_app!(scope, app_id)

    socket =
      socket
      |> assign(:page_title, "#{app.name} · Deployments")
      |> assign(:active_tab, :apps)
      |> assign(:app_detail_tab, :deployments)
      |> assign(:app, app)
      |> assign(:apps, Apps.list_app_choices(scope))
      |> assign(:selected_deployment_id, nil)
      |> assign(:confirming_cancel?, false)
      |> assign(:history_page, 1)
      |> assign(:app_memory, nil)
      |> assign(:detail_tabs, Layout.detail_tabs(app.slug == "catalogo", runtime_packages(app)))
      |> refresh_deployments(nil, nil)
      |> schedule_poll()

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
  def handle_event("deploy", _params, socket) do
    case Deployments.enqueue(socket.assigns.current_scope, socket.assigns.app, %{
           git_sha: "manual",
           triggered_by: "manual"
         }) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:history_page, 1)
         |> refresh_deployments(nil, true)
         |> schedule_poll()
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
         |> refresh_from_db()
         |> put_flash(:info, "Deploy ##{deployment.id} cancelled")}

      {:error, :no_active_deployment} ->
        {:noreply, put_flash(socket, :error, "No deploy queued or running")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not cancel the deploy")}
    end
  end

  def handle_event("select_app", %{"app_id" => app_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/apps/#{app_id}/deployments")}
  end

  def handle_event("view_deploy_log", %{"id" => id}, socket) do
    if socket.assigns.deploying? do
      {:noreply, socket}
    else
      # Re-stream the history so the viewed row highlights without a reload.
      {:noreply, refresh_deployments(socket, String.to_integer(id), false)}
    end
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    {:noreply,
     socket
     |> assign(:history_page, parse_page(page))
     |> refresh_deployments(socket.assigns.selected_deployment_id, socket.assigns.deploying?)}
  end

  @impl true
  def handle_info(:load_app_memory, socket) do
    {:noreply, assign(socket, :app_memory, RuntimeMemory.for_app(socket.assigns.app))}
  end

  def handle_info(:poll_deployments, socket) do
    {:noreply, refresh_from_db(socket)}
  end

  def handle_info({:deployment_changed, app_id}, socket)
      when app_id == socket.assigns.app.id do
    {:noreply, refresh_from_db(socket)}
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

          <div id="app-deployments" class="space-y-4 p-4">
            <div :if={@viewed_deployment} class="space-y-1.5">
              <div class="flex flex-wrap items-center justify-between gap-2 px-0.5">
                <div class="space-y-0.5">
                  <span class="block font-mono text-[10px] font-semibold uppercase tracking-widest text-hd-muted">
                    Build Output Stream logs
                  </span>
                  <span
                    :if={@selected_deployment_id && @viewed_deployment}
                    class="font-mono text-[10px] text-hd-muted"
                  >
                    Viewing deploy #{@viewed_deployment.id} · click another row in history to switch
                  </span>
                </div>
                <div class="flex flex-wrap items-center gap-3">
                  <span
                    :if={Deployments.duration(@viewed_deployment)}
                    class="font-mono text-[11px] tabular-nums text-hd-text"
                  >
                    Duration: {Deployments.format_duration(Deployments.duration(@viewed_deployment))}
                  </span>
                  <span
                    :if={@deploying?}
                    class="flex items-center gap-1 font-mono text-[11px] text-hd-orange"
                  >
                    <span class="size-1 animate-ping rounded-full bg-hd-orange" />
                    Compiling OTP release…
                  </span>
                </div>
              </div>
              <div :if={@deploying?} class="h-1 overflow-hidden rounded-full bg-hd-aside">
                <div class="deploy-progress h-full rounded-full" />
              </div>
              <.deploy_terminal
                id={"deploy-terminal-#{@viewed_deployment.id}"}
                deployment={@viewed_deployment}
                active?={@deploying?}
                duration={Deployments.format_duration(Deployments.duration(@viewed_deployment))}
              />
            </div>

            <div class="overflow-hidden rounded-md border border-hd-border bg-hd-card">
              <div class="border-b border-hd-border bg-hd-aside px-4 py-2">
                <span class="font-display text-xs font-semibold text-hd-text">
                  Deployments Version History
                </span>
              </div>
              <div id="deployments-history" class="overflow-x-auto">
                <table class="paas-table w-full text-left font-mono">
                  <thead>
                    <tr>
                      <th>Build Status</th>
                      <th>Commit/SHA Code</th>
                      <th>Trigger</th>
                      <th>Duration</th>
                      <th>Executed Timestamp</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody id="deployments" phx-update="stream">
                    <tr :if={@deployments_empty?} id="deployments-empty">
                      <td colspan="6" class="py-6 text-center text-xs text-hd-muted">
                        No deployments registered yet. Click "Deploy now" to launch container builds.
                      </td>
                    </tr>
                    <tr
                      :for={{id, deployment} <- @streams.deployments}
                      id={id}
                      class={[
                        "transition-colors",
                        @viewed_deployment && @viewed_deployment.id == deployment.id &&
                          "bg-hd-aside/60"
                      ]}
                    >
                      <td><.deploy_status_badge status={deployment.status} /></td>
                      <td>
                        <span class="rounded border border-hd-border bg-hd-aside px-1.5 py-0.5 text-[10px] text-hd-orange">
                          {deployment.git_sha}
                        </span>
                      </td>
                      <td class="text-[11px] text-hd-muted">{deployment.triggered_by}</td>
                      <td class="text-[11px] tabular-nums text-hd-text">
                        {Deployments.format_duration(Deployments.duration(deployment))}
                      </td>
                      <td class="text-[11px] text-hd-muted">
                        {format_datetime(deployment.started_at || deployment.inserted_at)}
                      </td>
                      <td class="text-right">
                        <button
                          :if={not @deploying?}
                          id={"view-deploy-log-#{deployment.id}"}
                          type="button"
                          phx-click="view_deploy_log"
                          phx-value-id={deployment.id}
                          aria-pressed={
                            to_string(
                              @viewed_deployment != nil and @viewed_deployment.id == deployment.id
                            )
                          }
                          class={[
                            "rounded border px-2 py-0.5 font-mono text-[10px] transition-colors",
                            @viewed_deployment && @viewed_deployment.id == deployment.id &&
                              "border-hd-orange/50 bg-hd-orange/10 text-hd-orange",
                            (!@viewed_deployment || @viewed_deployment.id != deployment.id) &&
                              "border-hd-border text-hd-muted hover:border-hd-orange/40 hover:text-hd-orange"
                          ]}
                        >
                          View log
                        </button>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
              <div
                :if={@history_total_pages > 1}
                id="deployments-pagination"
                class="flex flex-wrap items-center justify-between gap-3 border-t border-hd-border bg-hd-aside px-4 py-2"
              >
                <span
                  id="deployments-page-status"
                  class="font-mono text-[11px] tabular-nums text-hd-muted"
                >
                  {history_range(@history_page, @history_total)} of {@history_total}
                </span>
                <div class="flex items-center gap-2">
                  <button
                    id="deployments-page-prev"
                    type="button"
                    phx-click="paginate"
                    phx-value-page={@history_page - 1}
                    disabled={@history_page <= 1}
                    class="paas-btn-secondary px-2 py-1 text-[10px] uppercase disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-40"
                  >
                    <.icon name="hero-chevron-left" class="size-3.5" /> Prev
                  </button>
                  <span class="font-mono text-[10px] uppercase tracking-widest text-hd-muted">
                    Page {@history_page}/{@history_total_pages}
                  </span>
                  <button
                    id="deployments-page-next"
                    type="button"
                    phx-click="paginate"
                    phx-value-page={@history_page + 1}
                    disabled={@history_page >= @history_total_pages}
                    class="paas-btn-secondary px-2 py-1 text-[10px] uppercase disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-40"
                  >
                    Next <.icon name="hero-chevron-right" class="size-3.5" />
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp refresh_from_db(socket) do
    deploying? = Deployments.deploying?(socket.assigns.current_scope, socket.assigns.app)
    selected_id = if deploying?, do: nil, else: socket.assigns.selected_deployment_id

    socket
    |> refresh_deployments(selected_id, deploying?)
    |> schedule_poll()
  end

  defp refresh_deployments(socket, selected_id, deploying?) do
    scope = socket.assigns.current_scope
    app = socket.assigns.app
    history = Deployments.page_for_app(scope, app, socket.assigns.history_page)

    deploying? =
      case deploying? do
        nil -> Deployments.deploying?(scope, app)
        other -> other
      end

    socket
    |> assign(:history_page, history.page)
    |> assign(:history_total, history.total)
    |> assign(:history_total_pages, history.total_pages)
    |> assign(:deployments_empty?, history.total == 0)
    |> assign(:selected_deployment_id, selected_id)
    |> assign(:viewed_deployment, load_viewed(app, history.entries, selected_id, deploying?))
    |> assign(:deploying?, deploying?)
    |> stream(:deployments, history.entries, reset: true)
  end

  defp load_viewed(app, deployments, selected_id, deploying?) do
    case viewed_summary(deployments, selected_id, deploying?) do
      nil -> nil
      summary -> Deployments.get_with_log!(app, summary.id)
    end
  end

  defp viewed_summary(deployments, selected_id, deploying?) do
    cond do
      deploying? ->
        Enum.find(deployments, &(&1.status in [:queued, :running])) || List.first(deployments)

      selected_id ->
        Enum.find(deployments, &(&1.id == selected_id)) || %{id: selected_id}

      true ->
        List.first(deployments)
    end
  end

  defp schedule_poll(socket) do
    if connected?(socket) and socket.assigns.deploying? do
      Process.send_after(self(), :poll_deployments, @poll_ms)
    end

    socket
  end

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp history_range(_page, 0), do: "0-0"

  defp history_range(page, total) when is_integer(page) and is_integer(total) do
    page_size = Deployments.history_page_size()
    from = (page - 1) * page_size + 1
    to = min(page * page_size, total)
    "#{from}-#{to}"
  end

  defp runtime_packages(app), do: RuntimePackages.resolve(app).packages

  defp format_datetime(nil), do: "—"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end
end
