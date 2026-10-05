defmodule CleatDeploy.Analytics.SummaryStub do
  @moduledoc false

  @empty_app %{
    pageviews: 0,
    uniques: 0,
    series: [],
    paths: [],
    referrers: [],
    utm: [],
    stale: false
  }

  def visited(_server) do
    rows = Application.get_env(:cleat_deploy, :analytics_visited_stub, [])

    if Application.get_env(:cleat_deploy, :analytics_visited_stale, false) do
      {:ok, rows, stale: true}
    else
      {:ok, rows}
    end
  end

  def app(_server, _host, _range) do
    if Application.get_env(:cleat_deploy, :analytics_app_fail, false) do
      {:error, :sidecar_down}
    else
      {:ok, Application.get_env(:cleat_deploy, :analytics_app_stub, @empty_app)}
    end
  end
end
