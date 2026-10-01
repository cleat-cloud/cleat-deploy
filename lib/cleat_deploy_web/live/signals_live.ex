defmodule CleatDeployWeb.SignalsLive do
  use CleatDeployWeb, :live_view

  alias CleatDeploy.Apps
  alias CleatDeploy.Signals

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Saúde")
     |> assign(:active_tab, :signals)
     |> assign(:selected, nil)
     |> assign(:metrics, nil)
     |> assign(:incident, nil)
     |> assign(:rows, [])
     |> assign(:alerts, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params["app"])}
  end

  @impl true
  def handle_event("ack", %{"id" => id}, socket) do
    with {alert_id, ""} <- Integer.parse(id),
         {:ok, _alert} <- Signals.ack_alert(socket.assigns.current_scope, alert_id) do
      {:noreply, reload(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Não foi possível confirmar o alerta")}
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
      <div id="signals-overview" class="space-y-4">
        <div class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <p class="font-mono text-[10px] font-semibold tracking-wider text-hd-muted uppercase">
              Cleat Signals
            </p>
            <h2 class="font-display text-xl font-semibold tracking-tight">Saúde das aplicações</h2>
            <p class="mt-1 text-sm text-hd-muted">
              Detecte degradação e o release que antecedeu a mudança, sem abrir SSH.
            </p>
          </div>
        </div>

        <div class="grid gap-4 md:grid-cols-3">
          <.metric_card
            title="Saudáveis"
            value={Integer.to_string(count_status(@rows, :healthy))}
            hint="No ar"
            icon="hero-heart"
          />
          <.metric_card
            title="Degradadas"
            value={Integer.to_string(count_status(@rows, :degraded))}
            hint="Taxa de erro ou saturação"
            icon="hero-exclamation-triangle"
          />
          <.metric_card
            title="Indisponíveis"
            value={Integer.to_string(count_status(@rows, :down))}
            hint="Último deploy falhou"
            icon="hero-signal-slash"
          />
        </div>

        <section class="paas-card overflow-hidden">
          <div class="border-b border-hd-border px-4 py-3">
            <h3 class="font-mono text-[10px] font-semibold tracking-wider text-hd-muted uppercase">
              Overview
            </h3>
          </div>
          <div :if={@rows == []} class="px-4 py-8 text-center text-sm text-hd-muted">
            Nenhuma aplicação neste tenant.
          </div>
          <table :if={@rows != []} id="signals-health-table" class="w-full text-left text-sm">
            <thead class="font-mono text-[10px] tracking-wider text-hd-muted uppercase">
              <tr class="border-b border-hd-border">
                <th class="px-4 py-2 font-medium">App</th>
                <th class="px-4 py-2 font-medium">Estado</th>
                <th class="px-4 py-2 font-medium">Motivo</th>
                <th class="px-4 py-2 font-medium">Release</th>
                <th class="px-4 py-2 font-medium">Erros</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={row <- @rows}
                id={"signals-app-#{row.slug}"}
                class="border-b border-hd-border/60 last:border-0"
              >
                <td class="px-4 py-2">
                  <.link
                    id={"signals-app-link-#{row.slug}"}
                    patch={~p"/signals?app=#{row.slug}"}
                    class="font-medium text-hd-text hover:text-hd-orange"
                  >
                    {row.slug}
                  </.link>
                </td>
                <td class="px-4 py-2">
                  <span
                    id={"signals-status-#{row.slug}"}
                    class={[
                      "rounded border px-2 py-0.5 font-mono text-[10px] font-semibold uppercase",
                      status_class(row.status)
                    ]}
                  >
                    {status_label(row.status)}
                  </span>
                </td>
                <td class="px-4 py-2 font-mono text-[11px] text-hd-muted">
                  {reason_label(row.reasons)}
                </td>
                <td class="px-4 py-2 font-mono text-[11px] text-hd-muted">
                  {release_label(row.preceding_release)}
                </td>
                <td class="px-4 py-2 font-mono tabular-nums">{row.error_count}</td>
              </tr>
            </tbody>
          </table>
        </section>

        <section id="signals-alerts" class="paas-card overflow-hidden">
          <div class="border-b border-hd-border px-4 py-3">
            <h3 class="font-mono text-[10px] font-semibold tracking-wider text-hd-muted uppercase">
              Alertas
            </h3>
          </div>
          <div :if={@alerts == []} class="px-4 py-6 text-sm text-hd-muted">
            Nenhum alerta disparado.
          </div>
          <ul :if={@alerts != []} class="divide-y divide-hd-border">
            <li
              :for={alert <- @alerts}
              id={"signals-alert-#{alert.id}"}
              class="flex flex-wrap items-center justify-between gap-3 px-4 py-3"
            >
              <div>
                <p class="text-sm font-medium">{alert.message}</p>
                <p class="font-mono text-[11px] text-hd-muted">
                  {alert.rule} · {alert.status} · {alert.channel}
                </p>
              </div>
              <button
                :if={alert.status == "firing"}
                id={"signals-ack-#{alert.id}"}
                type="button"
                phx-click="ack"
                phx-value-id={alert.id}
                class="paas-btn-secondary px-3 py-1.5 text-xs"
              >
                Confirmar
              </button>
            </li>
          </ul>
        </section>

        <div :if={@selected} id="signals-detail" class="grid gap-4 lg:grid-cols-2">
          <.area_chart
            :if={@metrics}
            id="chart-signals-errors"
            title={"Erros · #{@selected.slug}"}
            current={if @metrics, do: Integer.to_string(@metrics.red.errors)}
            hint="Janela atual"
            series={error_series(@metrics)}
          />
          <section id="signals-timeline" class="paas-card p-4">
            <h3 class="font-mono text-[10px] font-semibold tracking-wider text-hd-muted uppercase">
              Timeline do incidente
            </h3>
            <p :if={@incident && @incident.events == []} class="mt-3 text-sm text-hd-muted">
              Sem eventos nesta janela.
            </p>
            <ol :if={@incident && @incident.events != []} class="mt-3 space-y-2">
              <li
                :for={event <- @incident.events}
                class="rounded-md border border-hd-border bg-hd-aside px-3 py-2"
              >
                <p class="font-mono text-[10px] tracking-wider text-hd-muted uppercase">
                  {event.kind}
                </p>
                <p class="text-sm">{event.summary}</p>
              </li>
            </ol>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load(socket, app_param) do
    scope = socket.assigns.current_scope
    rows = Signals.health_overview(scope)
    alerts = Signals.list_alerts(scope)

    socket
    |> assign(:rows, rows)
    |> assign(:alerts, alerts)
    |> assign_selected(scope, app_param)
  end

  defp reload(socket) do
    slug = socket.assigns.selected && socket.assigns.selected.slug
    load(socket, slug)
  end

  defp assign_selected(socket, _scope, param) when param in [nil, ""] do
    socket
    |> assign(:selected, nil)
    |> assign(:metrics, nil)
    |> assign(:incident, nil)
  end

  defp assign_selected(socket, scope, param) do
    case fetch_app(scope, param) do
      {:ok, app} ->
        metrics = fetch_ok(Signals.metrics(scope, app, range: "1h"))
        incident = fetch_ok(Signals.incident(scope, app, range: "24h"))

        socket
        |> assign(:selected, app)
        |> assign(:metrics, metrics)
        |> assign(:incident, incident)

      :error ->
        socket
        |> assign(:selected, nil)
        |> assign(:metrics, nil)
        |> assign(:incident, nil)
        |> put_flash(:error, "Aplicação não encontrada")
    end
  end

  defp fetch_app(scope, value) do
    {:ok, Apps.get_app_by_slug!(scope, value)}
  rescue
    Ecto.NoResultsError -> :error
  end

  defp fetch_ok({:ok, value}), do: value
  defp fetch_ok(_), do: nil

  defp count_status(rows, status), do: Enum.count(rows, &(&1.status == status))

  defp status_label(:healthy), do: "saudável"
  defp status_label(:degraded), do: "degradada"
  defp status_label(:down), do: "indisponível"
  defp status_label(_), do: "desconhecida"

  defp status_class(:healthy), do: "border-hd-green/40 bg-hd-green/10 text-hd-green"
  defp status_class(:degraded), do: "border-hd-orange/40 bg-hd-orange/10 text-hd-orange"
  defp status_class(:down), do: "border-rose-500/40 bg-rose-500/10 text-rose-400"
  defp status_class(_), do: "border-hd-border bg-hd-aside text-hd-muted"

  defp reason_label([]), do: "—"
  defp reason_label(reasons), do: Enum.map_join(reasons, ", ", &reason_name/1)

  defp reason_name(:error_rate), do: "taxa de erro"
  defp reason_name(:unavailability), do: "indisponibilidade"
  defp reason_name(:saturation), do: "saturação"
  defp reason_name(other), do: to_string(other)

  defp release_label(nil), do: "—"
  defp release_label(%{git_sha: sha}) when is_binary(sha), do: String.slice(sha, 0, 8)
  defp release_label(_), do: "—"

  defp error_series(nil), do: []

  defp error_series(%{series: series}) do
    Enum.map(series, fn point -> %{t: point.t, v: point.errors * 1.0} end)
  end
end
