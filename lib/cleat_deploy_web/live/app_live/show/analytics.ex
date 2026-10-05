defmodule CleatDeployWeb.AppLive.Show.Analytics do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias CleatDeploy.Analytics
  alias CleatDeploy.Apps

  def assigns(socket) do
    socket
    |> assign(:analytics_range, "24h")
    |> assign(:analytics_summary, nil)
  end

  def maybe_load(socket, :analytics, params) do
    socket
    |> assign(:analytics_range, Analytics.normalize_range(params["range"]))
    |> load_summary()
  end

  def maybe_load(socket, _tab, _params), do: socket

  def handle_event("toggle_analytics_inject", _params, socket) do
    app = socket.assigns.app
    enabled = not app.analytics_inject

    case Apps.set_analytics_inject(socket.assigns.current_scope, app, enabled) do
      {:ok, updated} ->
        updated = Apps.get_app!(socket.assigns.current_scope, updated.id)

        socket =
          socket
          |> assign(:app, updated)
          |> put_flash(:info, inject_flash(enabled))

        socket =
          if socket.assigns.app_detail_tab == :analytics do
            load_summary(socket)
          else
            socket
          end

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update analytics inject")}
    end
  end

  defp load_summary(socket) do
    app = socket.assigns.app

    summary =
      if app.analytics_inject do
        Analytics.app_summary(app, socket.assigns.analytics_range)
      end

    assign(socket, :analytics_summary, summary)
  end

  defp inject_flash(true), do: "Analytics inject on. Deploy to apply Caddy."
  defp inject_flash(false), do: "Analytics inject off. Deploy to apply Caddy."
end
