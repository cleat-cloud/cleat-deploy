defmodule CleatDeployWeb.AppLive.Show.Analytics do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias CleatDeploy.Analytics.Summary
  alias CleatDeploy.Apps

  @empty_summary %{
    pageviews: 0,
    uniques: 0,
    series: [],
    paths: [],
    referrers: [],
    utm: [],
    stale: false
  }

  def assigns(socket) do
    socket
    |> assign(:analytics_range, "24h")
    |> assign(:analytics_summary, nil)
  end

  def maybe_load(socket, :analytics, params) do
    socket
    |> assign(:analytics_range, sanitize_range(params["range"]))
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
        fetch_summary(app, socket.assigns.analytics_range)
      end

    assign(socket, :analytics_summary, summary)
  end

  defp fetch_summary(app, range) do
    case Summary.app(app.server, summary_host(app), range) do
      {:ok, map} when is_map(map) -> map
      {:error, _} -> @empty_summary
      _ -> @empty_summary
    end
  end

  defp summary_host(%{host: host}) when is_binary(host) do
    host
    |> String.split(",")
    |> Enum.map(&normalize_host/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp summary_host(_app), do: ""

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("http://", "")
    |> String.replace_prefix("https://", "")
    |> String.split(":")
    |> hd()
  end

  defp sanitize_range(range) when range in ["24h", "7d", "90d"], do: range
  defp sanitize_range(_), do: "24h"

  defp inject_flash(true), do: "Analytics inject on. Deploy to apply Caddy."
  defp inject_flash(false), do: "Analytics inject off. Deploy to apply Caddy."
end
