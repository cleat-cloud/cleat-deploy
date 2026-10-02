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
    {:ok, Application.get_env(:cleat_deploy, :analytics_visited_stub, [])}
  end

  def app(_server, _host, _range) do
    {:ok, Application.get_env(:cleat_deploy, :analytics_app_stub, @empty_app)}
  end
end
