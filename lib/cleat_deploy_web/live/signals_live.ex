defmodule CleatDeployWeb.SignalsLive do
  use CleatDeployWeb, :live_view

  alias CleatDeploy.Apps
  alias CleatDeploy.Observability
  alias CleatDeploy.Signals
  alias CleatDeploy.Signals.Traces

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
     |> assign(:alerts, [])
     |> assign(:ingest, nil)
     |> assign(:traces, [])
     |> assign(:log_jumps, [])
     |> assign(:trace_id, nil)
     |> assign(:waterfall, nil)
     |> assign(:service_map, nil)
     |> assign(:sampling_form, sampling_form(0.0))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params["app"], params["trace_id"])}
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

  def handle_event("set_sampling", %{"sampling" => %{"rate" => rate}}, socket) do
    app = socket.assigns.selected

    with true <- not is_nil(app),
         {:ok, parsed} <- parse_rate(rate),
         {:ok, _} <- Traces.set_sampling(socket.assigns.current_scope, app, parsed) do
      {:noreply,
       socket
       |> put_flash(:info, "Amostragem atualizada")
       |> reload()}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Taxa inválida. Use um valor entre 0 e 1.")}
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
      <div id="signals-overview" class="space-y-5">
        <div class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h2 class="text-xl font-medium tracking-tight">Saúde das aplicações</h2>
            <p class="mt-1 text-xs text-hd-muted">
              Detecte degradação e o release que antecedeu a mudança, sem abrir SSH.
            </p>
          </div>
        </div>

        <div
          :if={@ingest && (!@ingest.enabled || @ingest.stale)}
          id="signals-ingest-banner"
          class="rounded-lg border border-hd-orange/30 px-4 py-3 text-[13px]"
        >
          <p :if={!@ingest.enabled} class="font-medium text-hd-orange">
            Coletor de logs desligado — os números abaixo não refletem a realidade.
          </p>
          <p :if={@ingest.enabled} class="font-medium text-hd-orange">
            Ingestão de logs parada{ingest_since(@ingest)} — os números abaixo podem estar desatualizados.
          </p>
          <p
            :if={@ingest.enabled && @ingest.last_failures && @ingest.last_failures > 0}
            class="mt-1 text-hd-muted"
          >
            Última coleta falhou em {ingest_failed_apps(@ingest)}.
          </p>
          <p :if={!@ingest.enabled} class="mt-1 font-mono text-xs text-hd-muted">
            Ligue LOG_COLLECTOR_ENABLED=true e reinicie o painel para retomar a coleta.
          </p>
          <p :if={@ingest.enabled} class="mt-1 font-mono text-xs text-hd-muted">
            Verifique a fila :logs do Oban e o acesso SSH do painel aos servidores.
          </p>
        </div>

        <div class="grid gap-3 md:grid-cols-3">
          <.metric_card
            title="Saudáveis"
            value={Integer.to_string(count_status(@rows, :healthy))}
            hint="No ar"
          />
          <.metric_card
            title="Degradadas"
            value={Integer.to_string(count_status(@rows, :degraded))}
            hint="Taxa de erro ou saturação"
          />
          <.metric_card
            title="Indisponíveis"
            value={Integer.to_string(count_status(@rows, :down))}
            hint="Último deploy falhou"
          />
        </div>

        <section class="paas-card overflow-hidden">
          <div class="border-b border-hd-border px-5 py-3.5">
            <h3 class="text-sm font-medium text-hd-text">
              Overview
            </h3>
          </div>
          <div :if={@rows == []} class="px-4 py-8 text-center text-sm text-hd-muted">
            Nenhuma aplicação neste tenant.
          </div>
          <table :if={@rows != []} id="signals-health-table" class="w-full text-left text-sm">
            <thead class="font-mono text-xs text-hd-muted">
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
                    class={["flex items-center gap-1.5 font-mono text-xs", status_class(row.status)]}
                  >
                    <span class={["size-1.5 rounded-full", status_dot(row.status)]} />
                    {status_label(row.status)}
                  </span>
                </td>
                <td class="px-4 py-2 font-mono text-xs text-hd-muted">
                  {reason_label(row.reasons)}
                </td>
                <td class="px-4 py-2 font-mono text-xs text-hd-muted">
                  {release_label(row.preceding_release)}
                </td>
                <td class="px-4 py-2 font-mono tabular-nums">
                  {if ingest_blind?(@ingest), do: "—", else: row.error_count}
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section id="signals-alerts" class="paas-card overflow-hidden">
          <div class="border-b border-hd-border px-5 py-3.5">
            <h3 class="text-sm font-medium text-hd-text">
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
                <p class="font-mono text-xs text-hd-muted">
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
            <h3 class="font-mono text-xs text-hd-muted">
              Timeline do incidente
            </h3>
            <p :if={@incident && @incident.events == []} class="mt-3 text-sm text-hd-muted">
              Sem eventos nesta janela.
            </p>
            <ol :if={@incident && @incident.events != []} class="mt-3 space-y-2">
              <li
                :for={event <- @incident.events}
                class="rounded-lg border border-hd-border bg-hd-aside px-3 py-2"
              >
                <p class="font-mono text-xs text-hd-muted">
                  {event.kind}
                </p>
                <p class="text-sm">{event.summary}</p>
              </li>
            </ol>
          </section>
        </div>

        <div :if={@selected} class="grid gap-4 lg:grid-cols-2">
          <section id="signals-traces" class="paas-card overflow-hidden">
            <div class="border-b border-hd-border px-4 py-3">
              <h3 class="font-mono text-xs text-hd-muted">
                Traces
              </h3>
            </div>
            <div :if={@traces == []} class="px-4 py-6 text-sm text-hd-muted">
              Nenhum trace nesta janela. A taxa 0 desliga a ingestão.
            </div>
            <ul :if={@traces != []} class="divide-y divide-hd-border">
              <li :for={trace <- @traces} class="px-4 py-3">
                <.link
                  id={"signals-trace-#{trace.trace_id}"}
                  patch={~p"/signals?app=#{@selected.slug}&trace_id=#{trace.trace_id}"}
                  class="font-medium text-hd-text hover:text-hd-orange"
                >
                  {trace.root_name}
                </.link>
                <p class="font-mono text-xs text-hd-muted">
                  {trace.span_count} spans · {div(trace.duration_ns, 1_000_000)} ms
                </p>
              </li>
            </ul>
            <div :if={@log_jumps != []} class="border-t border-hd-border px-4 py-3">
              <p class="font-mono text-xs text-hd-muted">
                Logs → traces
              </p>
              <ul class="mt-2 space-y-1">
                <li :for={jump <- @log_jumps}>
                  <.link
                    id={"signals-log-jump-#{jump.trace_id}"}
                    patch={~p"/signals?app=#{@selected.slug}&trace_id=#{jump.trace_id}"}
                    class="text-sm text-hd-orange hover:underline"
                  >
                    {jump.message}
                  </.link>
                </li>
              </ul>
            </div>
          </section>

          <section id="signals-sampling" class="paas-card p-4">
            <h3 class="font-mono text-xs text-hd-muted">
              Amostragem
            </h3>
            <p class="mt-1 text-sm text-hd-muted">
              Fração de traces gravados (0 desliga, 1 grava todos).
            </p>
            <.form
              for={@sampling_form}
              id="signals-sampling-form"
              phx-submit="set_sampling"
              class="mt-3 flex flex-wrap items-end gap-3"
            >
              <.input
                field={@sampling_form[:rate]}
                type="number"
                min="0"
                max="1"
                step="0.01"
                label="Taxa"
              />
              <button type="submit" class="paas-btn-secondary px-3 py-1.5 text-xs">
                Salvar amostragem
              </button>
            </.form>
          </section>
        </div>

        <div :if={@waterfall} class="grid gap-4 lg:grid-cols-2">
          <section id="signals-waterfall" class="paas-card p-4">
            <h3 class="font-mono text-xs text-hd-muted">
              Waterfall
            </h3>
            <div class="mt-3 space-y-1">
              <div
                :for={span <- @waterfall.spans}
                id={"signals-span-#{span.span_id}"}
                class="rounded-lg border border-hd-border bg-hd-aside px-3 py-2"
                style={"margin-left: #{span.depth * 16}px"}
              >
                <p class="text-sm font-medium">{span.name}</p>
                <p class="font-mono text-xs text-hd-muted">
                  {span.service_name} · {span.kind} · {div(span.duration_ns, 1_000_000)} ms
                </p>
              </div>
            </div>
          </section>
          <section id="signals-service-map" class="paas-card p-4">
            <h3 class="font-mono text-xs text-hd-muted">
              Mapa de serviços
            </h3>
            <p :if={@service_map && @service_map.edges == []} class="mt-3 text-sm text-hd-muted">
              Sem dependências neste trace.
            </p>
            <ul :if={@service_map && @service_map.edges != []} class="mt-3 space-y-1">
              <li
                :for={edge <- @service_map.edges}
                class="font-mono text-xs text-hd-muted"
              >
                {edge.from} → {edge.to} ({edge.count})
              </li>
            </ul>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load(socket, app_param, trace_id) do
    scope = socket.assigns.current_scope
    rows = Signals.health_overview(scope)
    alerts = Signals.list_alerts(scope)

    socket
    |> assign(:rows, rows)
    |> assign(:alerts, alerts)
    |> assign(:ingest, Observability.ingest_status())
    |> assign_selected(scope, app_param, trace_id)
  end

  defp reload(socket) do
    slug = socket.assigns.selected && socket.assigns.selected.slug
    load(socket, slug, socket.assigns.trace_id)
  end

  defp assign_selected(socket, _scope, param, _trace_id) when param in [nil, ""] do
    clear_selection(socket)
  end

  defp assign_selected(socket, scope, param, trace_id) do
    case fetch_app(scope, param) do
      {:ok, app} ->
        metrics = fetch_ok(Signals.metrics(scope, app, range: "1h"))
        incident = fetch_ok(Signals.incident(scope, app, range: "24h"))
        traces = Traces.list(scope, app)
        sampling = fetch_ok(Traces.get_sampling(scope, app))
        rate = (sampling && sampling.trace_sample_rate) || 0.0

        socket
        |> assign(:selected, app)
        |> assign(:metrics, metrics)
        |> assign(:incident, incident)
        |> assign(:traces, traces)
        |> assign(:log_jumps, log_jumps(scope, app, traces))
        |> assign(:sampling_form, sampling_form(rate))
        |> assign_trace(scope, app, trace_id)

      :error ->
        socket
        |> clear_selection()
        |> put_flash(:error, "Aplicação não encontrada")
    end
  end

  defp assign_trace(socket, _scope, _app, trace_id) when trace_id in [nil, ""] do
    socket
    |> assign(:trace_id, nil)
    |> assign(:waterfall, nil)
    |> assign(:service_map, nil)
  end

  defp assign_trace(socket, scope, app, trace_id) do
    case Traces.waterfall(scope, app, trace_id) do
      {:ok, waterfall} ->
        socket
        |> assign(:trace_id, waterfall.trace_id)
        |> assign(:waterfall, waterfall)
        |> assign(:service_map, Traces.service_map(scope, app, trace_id: waterfall.trace_id))

      {:error, :not_found} ->
        socket
        |> assign(:trace_id, nil)
        |> assign(:waterfall, nil)
        |> assign(:service_map, nil)
        |> put_flash(:error, "Trace não encontrado")
    end
  end

  defp clear_selection(socket) do
    socket
    |> assign(:selected, nil)
    |> assign(:metrics, nil)
    |> assign(:incident, nil)
    |> assign(:traces, [])
    |> assign(:log_jumps, [])
    |> assign(:trace_id, nil)
    |> assign(:waterfall, nil)
    |> assign(:service_map, nil)
    |> assign(:sampling_form, sampling_form(0.0))
  end

  defp log_jumps(scope, app, traces) do
    Enum.flat_map(traces, fn trace ->
      case Traces.logs(scope, app, trace.trace_id) do
        [log | _] -> [%{trace_id: trace.trace_id, message: log.message}]
        _ -> []
      end
    end)
  end

  defp sampling_form(rate) do
    to_form(%{"rate" => rate_string(rate)}, as: :sampling)
  end

  defp rate_string(rate) when is_integer(rate), do: Integer.to_string(rate)
  defp rate_string(rate) when is_float(rate), do: :erlang.float_to_binary(rate, decimals: 2)
  defp rate_string(_), do: "0.00"

  defp parse_rate(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {rate, ""} -> {:ok, rate}
      _ -> :error
    end
  end

  defp parse_rate(value) when is_number(value), do: {:ok, value / 1}
  defp parse_rate(_), do: :error

  defp fetch_app(scope, value) do
    {:ok, Apps.get_app_by_slug!(scope, value)}
  rescue
    Ecto.NoResultsError -> :error
  end

  defp fetch_ok({:ok, value}), do: value
  defp fetch_ok(_), do: nil

  defp count_status(rows, status), do: Enum.count(rows, &(&1.status == status))

  defp ingest_blind?(nil), do: false
  defp ingest_blind?(%{enabled: false}), do: true
  defp ingest_blind?(%{stale: stale}), do: stale

  defp ingest_since(%{last_run_at: nil}), do: ""
  defp ingest_since(%{last_run_at: at}), do: " desde #{Calendar.strftime(at, "%d/%m %H:%M UTC")}"

  defp ingest_failed_apps(%{last_failures: failures, last_apps: apps}) do
    "#{failures} de #{apps} aplicações"
  end

  defp status_label(:healthy), do: "saudável"
  defp status_label(:degraded), do: "degradada"
  defp status_label(:down), do: "indisponível"
  defp status_label(_), do: "desconhecida"

  defp status_class(:healthy), do: "text-hd-green"
  defp status_class(:degraded), do: "text-hd-orange"
  defp status_class(:down), do: "text-hd-red"
  defp status_class(_), do: "text-hd-muted"

  defp status_dot(:healthy), do: "bg-hd-green"
  defp status_dot(:degraded), do: "bg-hd-orange"
  defp status_dot(:down), do: "bg-hd-red"
  defp status_dot(_), do: "bg-hd-muted/50"

  defp reason_label([]), do: "—"
  defp reason_label(reasons), do: Enum.map_join(reasons, ", ", &reason_name/1)

  defp reason_name(:error_rate), do: "taxa de erro"
  defp reason_name(:unavailability), do: "indisponibilidade"
  defp reason_name(:deploy_failed), do: "deploy falhou"
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
