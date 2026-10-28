defmodule CleatDeployWeb.DeploymentLive.Index do
  use CleatDeployWeb, :live_view

  alias CleatDeploy.Deployments

  @poll_ms 15_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Deploys")
     |> assign(:active_tab, :deployments)
     |> assign(:query, "")
     |> assign(:status, :all)
     |> assign(:page, 1)
     |> assign(:total, 0)
     |> assign(:total_pages, 1)
     |> assign(:filtered?, false)
     |> assign(:deploying?, false)
     |> stream(:deployments, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> apply_params(params) |> restream() |> schedule_poll()}
  end

  @impl true
  def handle_event("filter_query", params, socket) do
    query = params["query"] || params["deployments_query"] || ""

    {:noreply, push_patch(socket, to: filter_path(socket, %{query: query, page: 1}))}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply,
     push_patch(socket, to: filter_path(socket, %{status: parse_status(status), page: 1}))}
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: filter_path(socket, %{page: parse_page(page)}))}
  end

  @impl true
  def handle_info(:poll_deployments, socket) do
    {:noreply, socket |> restream() |> schedule_poll()}
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
      <div id="deployments-index" class="space-y-4">
        <div>
          <p class="font-mono text-[10px] font-semibold tracking-wider text-hd-muted uppercase">
            Tenant history
          </p>
          <h2 class="font-display text-xl font-semibold tracking-tight">Deploys</h2>
          <p class="mt-1 text-sm text-hd-muted">
            Every build in this tenant. Open an app to read logs or cancel a run.
          </p>
        </div>

        <div class="overflow-hidden rounded-md border border-hd-border bg-hd-card">
          <div class="flex items-center justify-between border-b border-hd-border bg-hd-aside px-4 py-2.5">
            <div class="space-y-0.5">
              <h3 class="font-display text-xs font-semibold text-hd-text">Deployments</h3>
              <p class="text-[11px] text-hd-muted">Newest first · 10 per page</p>
            </div>
          </div>

          <.filters query={@query} status={@status} />

          <div class="overflow-x-auto">
            <table id="deployments-table" class="paas-table w-full text-left font-mono">
              <thead>
                <tr>
                  <th>App</th>
                  <th>Status</th>
                  <th>SHA/ref</th>
                  <th>Trigger</th>
                  <th>Duration</th>
                  <th>When</th>
                </tr>
              </thead>
              <tbody id="deployments-list" phx-update="stream">
                <tr :if={@total == 0 and not @filtered?} id="deployments-empty">
                  <td colspan="6" class="py-8 text-center text-hd-muted">
                    <p class="font-mono text-xs">No deployments yet.</p>
                  </td>
                </tr>
                <tr :if={@total == 0 and @filtered?} id="deployments-filter-empty">
                  <td colspan="6" class="py-8 text-center text-hd-muted">
                    <p class="font-mono text-xs">No deployments match this filter.</p>
                  </td>
                </tr>
                <tr :for={{id, deployment} <- @streams.deployments} id={id}>
                  <td>
                    <.link
                      id={"deployment-#{deployment.id}-app"}
                      navigate={~p"/apps/#{deployment.app.id}/deployments"}
                      class="font-medium text-hd-orange hover:text-hd-orange-dark"
                    >
                      {deployment.app.name}
                    </.link>
                  </td>
                  <td>
                    <.deploy_status_badge status={deployment.status} />
                  </td>
                  <td>
                    <span class="rounded border border-hd-border bg-hd-aside px-1.5 py-0.5 text-[10px] text-hd-orange">
                      {deployment.git_sha}
                    </span>
                    <span
                      :if={deployment.git_ref not in [nil, ""]}
                      class="mt-0.5 block text-[10px] text-hd-muted"
                    >
                      {deployment.git_ref}
                    </span>
                  </td>
                  <td class="text-[11px] text-hd-muted">{deployment.triggered_by}</td>
                  <td class="text-[11px] tabular-nums text-hd-text">
                    {Deployments.format_duration(Deployments.duration(deployment))}
                  </td>
                  <td class="text-[11px] text-hd-muted">
                    {format_datetime(deployment.started_at || deployment.inserted_at)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <.pagination
            :if={@total_pages > 1}
            page={@page}
            total={@total}
            total_pages={@total_pages}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp filters(assigns) do
    ~H"""
    <div class="space-y-2.5 border-b border-hd-border bg-hd-aside/40 px-4 py-3">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <.form
          for={to_form(%{"query" => @query})}
          id="deployments-filter"
          phx-change="filter_query"
          class="min-w-0 flex-1"
        >
          <label class="relative block max-w-md">
            <span class="sr-only">Filter deployments</span>
            <.icon
              name="hero-magnifying-glass"
              class="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-hd-muted"
            />
            <input
              type="search"
              name="query"
              id="deployments-query"
              value={@query}
              phx-debounce="150"
              placeholder="Filter by app name, slug, or host"
              class="paas-input w-full pl-9"
            />
          </label>
        </.form>
        <div class="flex flex-wrap items-center gap-1.5">
          <.status_chip id="deployments-filter-all" status={:all} current={@status}>
            All
          </.status_chip>
          <.status_chip id="deployments-filter-queued" status={:queued} current={@status}>
            queued
          </.status_chip>
          <.status_chip id="deployments-filter-running" status={:running} current={@status}>
            running
          </.status_chip>
          <.status_chip id="deployments-filter-success" status={:success} current={@status}>
            success
          </.status_chip>
          <.status_chip id="deployments-filter-failed" status={:failed} current={@status}>
            failed
          </.status_chip>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :status, :atom, required: true
  attr :current, :atom, required: true
  slot :inner_block, required: true

  defp status_chip(assigns) do
    assigns = assign(assigns, :active?, assigns.status == assigns.current)

    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="filter_status"
      phx-value-status={@status}
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

  attr :page, :integer, required: true
  attr :total, :integer, required: true
  attr :total_pages, :integer, required: true

  defp pagination(assigns) do
    ~H"""
    <div
      id="deployments-pagination"
      class="flex flex-wrap items-center justify-between gap-3 border-t border-hd-border bg-hd-aside px-4 py-2"
    >
      <span id="deployments-page-status" class="font-mono text-[11px] tabular-nums text-hd-muted">
        {page_range(@page, @total)} of {@total}
      </span>
      <div class="flex items-center gap-2">
        <button
          id="deployments-page-first"
          type="button"
          phx-click="paginate"
          phx-value-page={1}
          disabled={@page <= 1}
          title="First page"
          class="paas-btn-secondary px-2 py-1 text-[10px] uppercase disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-40"
        >
          <.icon name="hero-chevron-double-left" class="size-3.5" />
        </button>
        <button
          id="deployments-page-prev"
          type="button"
          phx-click="paginate"
          phx-value-page={@page - 1}
          disabled={@page <= 1}
          class="paas-btn-secondary px-2 py-1 text-[10px] uppercase disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-40"
        >
          <.icon name="hero-chevron-left" class="size-3.5" /> Prev
        </button>
        <span class="font-mono text-[10px] tracking-widest text-hd-muted uppercase">
          Page {@page}/{@total_pages}
        </span>
        <button
          id="deployments-page-next"
          type="button"
          phx-click="paginate"
          phx-value-page={@page + 1}
          disabled={@page >= @total_pages}
          class="paas-btn-secondary px-2 py-1 text-[10px] uppercase disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-40"
        >
          Next <.icon name="hero-chevron-right" class="size-3.5" />
        </button>
        <button
          id="deployments-page-last"
          type="button"
          phx-click="paginate"
          phx-value-page={@total_pages}
          disabled={@page >= @total_pages}
          title="Last page"
          class="paas-btn-secondary px-2 py-1 text-[10px] uppercase disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-40"
        >
          <.icon name="hero-chevron-double-right" class="size-3.5" />
        </button>
      </div>
    </div>
    """
  end

  defp apply_params(socket, params) do
    query = parse_query(params["query"])
    status = parse_status(params["status"])
    page = parse_page(params["page"])

    socket
    |> assign(:query, query)
    |> assign(:status, status)
    |> assign(:page, page)
    |> assign(:filtered?, query != "" or status != :all)
  end

  defp restream(socket) do
    scope = socket.assigns.current_scope

    history =
      Deployments.page_for_tenant(scope, socket.assigns.page,
        query: socket.assigns.query,
        status: socket.assigns.status
      )

    socket
    |> assign(:page, history.page)
    |> assign(:total, history.total)
    |> assign(:total_pages, history.total_pages)
    |> assign(:deploying?, Deployments.deploying_for_tenant?(scope))
    |> stream(:deployments, history.entries, reset: true)
  end

  defp schedule_poll(socket) do
    if connected?(socket) and socket.assigns.deploying? do
      Process.send_after(self(), :poll_deployments, @poll_ms)
    end

    socket
  end

  defp filter_path(socket, overrides) do
    attrs =
      Map.merge(
        %{query: socket.assigns.query, status: socket.assigns.status, page: socket.assigns.page},
        overrides
      )

    params =
      %{}
      |> put_query_param(attrs.query)
      |> put_status_param(attrs.status)
      |> put_page_param(attrs.page)

    if params == %{}, do: ~p"/deployments", else: ~p"/deployments?#{params}"
  end

  defp put_query_param(params, query) when query in [nil, ""], do: params
  defp put_query_param(params, query), do: Map.put(params, :query, query)

  defp put_status_param(params, :all), do: params
  defp put_status_param(params, status), do: Map.put(params, :status, Atom.to_string(status))

  defp put_page_param(params, page) when page in [nil, 1], do: params
  defp put_page_param(params, page), do: Map.put(params, :page, page)

  defp parse_query(nil), do: ""
  defp parse_query(query) when is_binary(query), do: String.trim(query)
  defp parse_query(_), do: ""

  defp parse_status("queued"), do: :queued
  defp parse_status("running"), do: :running
  defp parse_status("success"), do: :success
  defp parse_status("failed"), do: :failed
  defp parse_status(_), do: :all

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp parse_page(page) when is_integer(page) and page > 0, do: page
  defp parse_page(_), do: 1

  defp page_range(_page, 0), do: "0-0"

  defp page_range(page, total) when is_integer(page) and is_integer(total) do
    page_size = Deployments.history_page_size()
    from = (page - 1) * page_size + 1
    to = min(page * page_size, total)
    "#{from}-#{to}"
  end

  defp format_datetime(nil), do: "—"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end
end
