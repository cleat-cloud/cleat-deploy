defmodule CleatDeployWeb.Api.LogController do
  @moduledoc false

  use CleatDeployWeb, :controller

  alias CleatDeploy.Apps
  alias CleatDeploy.Observability
  alias CleatDeploy.Observability.LogEvent
  alias CleatDeploy.Servers
  alias CleatDeployWeb.Api.Serializer

  def index(conn, params) do
    reply(conn, params, fn scope, filters ->
      events = Observability.search(scope, filters)
      json(conn, %{data: Enum.map(events, &Serializer.log_event/1)})
    end)
  end

  def groups(conn, params) do
    reply(conn, params, fn scope, filters ->
      groups = Observability.group_errors(scope, filters)
      json(conn, %{data: Enum.map(groups, &Serializer.log_group/1)})
    end)
  end

  defp reply(conn, params, fun) do
    scope = conn.assigns.current_scope

    case filters(scope, params) do
      {:ok, filters} ->
        fun.(scope, filters)

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, :invalid, message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_request", details: %{message: message}})
    end
  end

  defp filters(scope, params) do
    with {:ok, app_id} <- app_filter(scope, params["app"]),
         {:ok, server_id} <- server_filter(scope, params["server"]),
         {:ok, severity} <- severity_filter(params["severity"], "severity"),
         {:ok, min_severity} <- severity_filter(params["min_severity"], "min_severity"),
         {:ok, since} <- time_filter(params["since"], "since"),
         {:ok, until} <- time_filter(params["until"], "until"),
         {:ok, limit} <- limit_filter(params["limit"]) do
      {:ok,
       %{
         app_id: app_id,
         server_id: server_id,
         unit: params["unit"],
         q: params["q"],
         severity: severity,
         min_severity: min_severity,
         release: params["release"],
         environment: params["environment"],
         since: since,
         until: until,
         limit: limit
       }}
    end
  end

  defp app_filter(_scope, value) when value in [nil, ""], do: {:ok, nil}

  defp app_filter(scope, value) do
    {:ok, resolve_app(scope, value).id}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp resolve_app(scope, value) do
    case Integer.parse(value) do
      {id, ""} -> Apps.get_app!(scope, id)
      _ -> Apps.get_app_by_slug!(scope, value)
    end
  end

  defp server_filter(_scope, value) when value in [nil, ""], do: {:ok, nil}

  defp server_filter(scope, value) do
    case Integer.parse(value) do
      {id, ""} -> {:ok, Servers.get_server!(scope, id).id}
      _ -> {:error, :invalid, "invalid server"}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp severity_filter(value, _key) when value in [nil, ""], do: {:ok, nil}

  defp severity_filter(value, key) do
    if value in LogEvent.severities() do
      {:ok, value}
    else
      {:error, :invalid, "invalid #{key}"}
    end
  end

  defp time_filter(nil, _key), do: {:ok, nil}
  defp time_filter("", _key), do: {:ok, nil}

  defp time_filter(value, key) do
    case Observability.parse_time(value) do
      {:ok, time} -> {:ok, time}
      {:error, :invalid} -> {:error, :invalid, "invalid #{key}"}
    end
  end

  defp limit_filter(value) do
    case Observability.parse_limit(value) do
      {:ok, limit} -> {:ok, limit}
      {:error, :invalid} -> {:error, :invalid, "invalid limit"}
    end
  end
end
