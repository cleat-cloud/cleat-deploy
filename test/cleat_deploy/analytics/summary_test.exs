defmodule CleatDeploy.Analytics.SummaryTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.Analytics.Summary

  test "visited uses the configured client" do
    Application.put_env(:cleat_deploy, :analytics_visited_stub, [
      %{host: "nfe.gestaobem.com", slug: "nfe-facil", pageviews: 42, id: 1, name: "NFe"}
    ])

    assert {:ok, [%{slug: "nfe-facil", pageviews: 42}]} =
             Summary.visited(%{host_ip: "203.0.113.9"})
  after
    Application.delete_env(:cleat_deploy, :analytics_visited_stub)
  end

  test "app returns the stub map" do
    server = %{host_ip: "203.0.113.9"}

    assert {:ok,
            %{
              pageviews: 0,
              uniques: 0,
              series: [],
              paths: [],
              referrers: [],
              utm: [],
              stale: false
            }} = Summary.app(server, "nfe.gestaobem.com", "24h")

    Application.put_env(:cleat_deploy, :analytics_app_stub, %{
      pageviews: 12,
      uniques: 4,
      series: [],
      paths: [%{path: "/login", pageviews: 8}],
      referrers: [%{referrer: "google.com", pageviews: 3}],
      utm: [%{source: "google", medium: "cpc", campaign: "a", pageviews: 2}],
      stale: false
    })

    assert {:ok, %{pageviews: 12, uniques: 4, stale: false}} =
             Summary.app(server, "nfe.gestaobem.com", "24h")
  after
    Application.delete_env(:cleat_deploy, :analytics_app_stub)
  end
end
