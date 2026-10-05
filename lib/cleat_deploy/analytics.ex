defmodule CleatDeploy.Analytics do
  @moduledoc """
  Spine analytics defaults. Collection lives on the VPS sidecar, not in cleat.db.
  """

  alias CleatDeploy.Analytics.Summary
  alias CleatDeploy.Apps.App

  @runtimes ~w(phoenix golang node rails rust gleam)
  @ranges ~w(24h 7d 90d)

  def listen_port do
    Application.get_env(:cleat_deploy, :analytics_listen_port, 8799)
  end

  def product_lp_slugs do
    Application.get_env(:cleat_deploy, :analytics_product_lp_slugs, [])
  end

  def default_inject?(runtime, slug) when is_binary(runtime) and is_binary(slug) do
    runtime in @runtimes or slug in product_lp_slugs()
  end

  def default_inject?(_, _), do: false

  def ranges, do: @ranges

  def normalize_range(range) when range in @ranges, do: range
  def normalize_range(_), do: "24h"

  def empty_summary(stale \\ false) do
    %{
      pageviews: 0,
      uniques: 0,
      series: [],
      paths: [],
      referrers: [],
      utm: [],
      stale: stale
    }
  end

  @doc """
  First public host of the app, normalized for the sidecar.
  """
  def summary_host(%{host: host}) when is_binary(host) do
    host
    |> String.split(",")
    |> Enum.map(&normalize_host/1)
    |> Enum.find("", &(&1 != ""))
  end

  def summary_host(_app), do: ""

  @doc """
  Pageview summary for one app, read from the sidecar.

  The sidecar unreachable returns an empty summary with `stale: true`: the
  tenant's site keeps serving and the caller can tell the numbers are missing
  instead of reading zero as a clean day.
  """
  def app_summary(%App{} = app, range) do
    range = normalize_range(range)

    case summary_host(app) do
      "" ->
        empty_summary(true)

      host ->
        case Summary.app(app.server, host, range) do
          {:ok, map} when is_map(map) -> Map.put_new(map, :stale, false)
          _ -> empty_summary(true)
        end
    end
  end

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("http://", "")
    |> String.replace_prefix("https://", "")
    |> String.split(":")
    |> hd()
  end
end
