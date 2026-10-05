defmodule CleatDeployWeb.Api.AnalyticsController do
  @moduledoc """
  Product analytics endpoints for the `cleat` CLI.

  `requested` reads Caddy's access log on the active server; `visited` and the
  per-app summary read the pageview sidecar. They are never mixed: an access
  hit is not a pageview and vice versa.
  """

  use CleatDeployWeb, :controller

  alias CleatDeploy.Analytics
  alias CleatDeploy.Apps
  alias CleatDeploy.Servers.Insights
  alias CleatDeployWeb.Api.Serializer

  def requested(conn, _params) do
    scope = conn.assigns.current_scope
    %{requested: rows} = Insights.requested_ranking(scope)

    json(conn, %{data: Enum.map(rows, &Serializer.analytics_requested/1)})
  end

  def visited(conn, _params) do
    scope = conn.assigns.current_scope
    %{stale: stale, visited: rows} = Insights.visited_apps(scope)

    json(conn, %{data: Enum.map(rows, &Serializer.analytics_visited/1), stale: stale})
  end

  def app_summary(conn, %{"app_id" => app_id} = params) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- resolve_app(scope, app_id) do
      range = Analytics.normalize_range(params["range"])

      json(conn, %{
        data: Serializer.analytics_summary(app, Analytics.app_summary(app, range), range)
      })
    else
      :error -> not_found(conn)
    end
  end

  defp resolve_app(scope, value) do
    {:ok, resolve(scope, value)}
  rescue
    Ecto.NoResultsError -> :error
  end

  defp resolve(scope, value) do
    case Integer.parse(value) do
      {id, ""} -> Apps.get_app!(scope, id)
      _ -> Apps.get_app_by_slug!(scope, value)
    end
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "not_found"})
end
