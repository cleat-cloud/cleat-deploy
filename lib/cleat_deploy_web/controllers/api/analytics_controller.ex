defmodule CleatDeployWeb.Api.AnalyticsController do
  @moduledoc """
  Product analytics endpoints for the `cleat` CLI.

  `requested` reads Caddy's access log on the active server; `visited` and the
  per-app summary read the pageview sidecar. They are never mixed: an access
  hit is not a pageview and vice versa.
  """

  use CleatDeployWeb, :controller

  alias CleatDeploy.Servers.Insights
  alias CleatDeployWeb.Api.Serializer

  def requested(conn, _params) do
    scope = conn.assigns.current_scope
    %{requested: rows} = Insights.requested_ranking(scope)

    json(conn, %{data: Enum.map(rows, &Serializer.analytics_requested/1)})
  end
end
