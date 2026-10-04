defmodule CleatDeployWeb.Api.SignalsController do
  @moduledoc false

  use CleatDeployWeb, :controller

  alias CleatDeploy.Apps
  alias CleatDeploy.Signals
  alias CleatDeploy.Signals.{Pages, Traces}
  alias CleatDeployWeb.Api.Serializer

  def health(conn, params) do
    scope = conn.assigns.current_scope

    case app_filter(scope, params["app"]) do
      {:ok, nil} ->
        rows = Signals.health_overview(scope)
        json(conn, %{data: Enum.map(rows, &Serializer.signal_health/1)})

      {:ok, app} ->
        rows =
          scope
          |> Signals.health_overview()
          |> Enum.filter(&(&1.app_id == app.id))

        json(conn, %{data: Enum.map(rows, &Serializer.signal_health/1)})

      :error ->
        not_found(conn)
    end
  end

  def metrics(conn, params) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- require_app(scope, params["app"]),
         {:ok, metrics} <- Signals.metrics(scope, app, range: params["range"] || "1h") do
      json(conn, %{data: Serializer.signal_metrics(metrics)})
    else
      :error -> not_found(conn)
      {:error, :not_found} -> not_found(conn)
    end
  end

  def pages(conn, params) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- require_app(scope, params["app"]),
         {:ok, pages} <- Pages.for_app(scope, app, range: params["range"] || "24h") do
      json(conn, %{data: Serializer.signal_pages(pages)})
    else
      :error -> not_found(conn)
      {:error, :not_found} -> not_found(conn)
    end
  end

  def alerts(conn, _params) do
    alerts = Signals.list_alerts(conn.assigns.current_scope)
    json(conn, %{data: Enum.map(alerts, &Serializer.signal_alert/1)})
  end

  def ack(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with {alert_id, ""} <- Integer.parse(id),
         {:ok, alert} <- Signals.ack_alert(scope, alert_id) do
      json(conn, %{data: Serializer.signal_alert(alert)})
    else
      :error -> not_found(conn)
      {:error, :not_found} -> not_found(conn)
      {:error, :invalid_status} -> unprocessable(conn, "alert is not firing")
      _other -> not_found(conn)
    end
  end

  def ingest_traces(conn, params) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- require_app(scope, params["app"]) do
      case Traces.ingest(scope, app, params) do
        {:ok, result} ->
          conn
          |> put_status(:accepted)
          |> json(%{data: result})

        {:error, :invalid_payload} ->
          unprocessable(conn, "payload must include resourceSpans")

        {:error, :not_found} ->
          not_found(conn)
      end
    else
      :error -> not_found(conn)
    end
  end

  def traces(conn, params) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- require_app(scope, params["app"]) do
      case params["trace_id"] do
        id when id in [nil, ""] ->
          rows = Traces.list(scope, app, service: params["service"])
          json(conn, %{data: Enum.map(rows, &Serializer.signal_trace/1)})

        trace_id ->
          case Traces.waterfall(scope, app, trace_id) do
            {:error, :not_found} ->
              not_found(conn)

            {:ok, waterfall} ->
              trace =
                scope
                |> Traces.list(app)
                |> Enum.find(&(&1.trace_id == waterfall.trace_id))

              json(conn, %{
                data:
                  Serializer.signal_trace_detail(%{
                    trace: trace,
                    spans: waterfall.spans,
                    service_map: Traces.service_map(scope, app, trace_id: waterfall.trace_id),
                    logs: Traces.logs(scope, app, trace_id)
                  })
              })
          end
      end
    else
      :error -> not_found(conn)
    end
  end

  def sampling(conn, params) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- require_app(scope, params["app"]),
         {:ok, sampling} <- Traces.get_sampling(scope, app) do
      json(conn, %{data: Serializer.signal_sampling(sampling)})
    else
      :error -> not_found(conn)
      {:error, :not_found} -> not_found(conn)
    end
  end

  def update_sampling(conn, params) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- require_app(scope, params["app"]),
         {:ok, rate} <- parse_rate(params["rate"]) do
      case Traces.set_sampling(scope, app, rate) do
        {:ok, sampling} ->
          json(conn, %{data: Serializer.signal_sampling(sampling)})

        {:error, %Ecto.Changeset{}} ->
          unprocessable(conn, "trace_sample_rate must be between 0 and 1")

        {:error, :not_found} ->
          not_found(conn)
      end
    else
      :error -> not_found(conn)
      :invalid_rate -> unprocessable(conn, "trace_sample_rate must be between 0 and 1")
    end
  end

  def incident(conn, params) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- require_app(scope, params["app"]),
         {:ok, incident} <- Signals.incident(scope, app, range: params["range"] || "24h") do
      json(conn, %{data: Serializer.signal_incident(incident)})
    else
      :error -> not_found(conn)
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp require_app(_scope, value) when value in [nil, ""], do: :error
  defp require_app(scope, value), do: app_filter(scope, value)

  defp app_filter(_scope, value) when value in [nil, ""], do: {:ok, nil}

  defp app_filter(scope, value) do
    {:ok, resolve_app(scope, value)}
  rescue
    Ecto.NoResultsError -> :error
  end

  defp resolve_app(scope, value) do
    case Integer.parse(value) do
      {id, ""} -> Apps.get_app!(scope, id)
      _ -> Apps.get_app_by_slug!(scope, value)
    end
  end

  defp parse_rate(value) when is_integer(value), do: {:ok, value * 1.0}
  defp parse_rate(value) when is_float(value), do: {:ok, value}

  defp parse_rate(value) when is_binary(value) do
    case Float.parse(value) do
      {rate, ""} -> {:ok, rate}
      _ -> :invalid_rate
    end
  end

  defp parse_rate(_), do: :invalid_rate

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "not_found"})

  defp unprocessable(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid_request", details: %{message: message}})
  end
end
