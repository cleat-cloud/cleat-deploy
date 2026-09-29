defmodule CleatDeployWeb.AppLive.Show.Logs do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias CleatDeploy.Observability

  def assigns(socket) do
    socket
    |> assign(:log_events, [])
    |> assign(:log_groups, [])
    |> assign(:log_filters, %{"q" => "", "min_severity" => "", "release" => ""})
  end

  def load(socket) do
    scope = socket.assigns.current_scope
    app = socket.assigns.app
    filters = query_filters(socket.assigns.log_filters, app)

    socket
    |> assign(:log_events, Observability.search(scope, filters))
    |> assign(:log_groups, Observability.group_errors(scope, Map.put(filters, :limit, 8)))
  end

  def handle_event("search_log_events", params, socket) do
    filters = %{
      "q" => params["q"] || "",
      "min_severity" => params["min_severity"] || "",
      "release" => params["release"] || ""
    }

    {:noreply, socket |> assign(:log_filters, filters) |> load()}
  end

  def handle_event("refresh_log_events", _params, socket) do
    {:noreply, load(socket)}
  end

  defp query_filters(filters, app) do
    min_severity =
      case filters["min_severity"] do
        value when value in [nil, "", "info"] -> nil
        value -> value
      end

    %{
      app_id: app.id,
      q: blank(filters["q"]),
      min_severity: min_severity,
      release: blank(filters["release"]),
      environment: app.branch,
      limit: 200
    }
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value
end
