defmodule CleatDeployWeb.Api.SignalsController do
  @moduledoc false

  use CleatDeployWeb, :controller

  alias CleatDeploy.Apps
  alias CleatDeploy.Signals
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

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "not_found"})

  defp unprocessable(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid_request", details: %{message: message}})
  end
end
