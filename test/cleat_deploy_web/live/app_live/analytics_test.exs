defmodule CleatDeployWeb.AppLive.AnalyticsTest do
  use CleatDeployWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias CleatDeploy.Apps
  alias CleatDeploy.RuntimeLogsFixtures
  alias CleatDeploy.TenancyFixtures

  setup :register_and_log_in_user
  setup :verify_on_exit!

  setup %{scope: scope} do
    stub(CleatDeploy.Apps.RuntimeControlMock, :run, fn _subject, _argv -> {:ok, ""} end)
    RuntimeLogsFixtures.stub_success()

    server = TenancyFixtures.server_fixture(scope)
    %{server: server}
  end

  test "analytics tab shows off state for static", %{conn: conn, scope: scope, server: server} do
    app = TenancyFixtures.app_fixture(scope, server, %{runtime: "static", slug: "memo-z"})
    {:ok, view, html} = live(conn, ~p"/apps/#{app.id}?tab=analytics")
    assert html =~ "Not measuring"
    assert has_element?(view, "#analytics-inject-toggle")
  end

  test "analytics tab shows stubbed totals when on", %{conn: conn, scope: scope, server: server} do
    app = TenancyFixtures.app_fixture(scope, server, %{runtime: "phoenix", slug: "nfe-z"})

    Application.put_env(:cleat_deploy, :analytics_app_stub, %{
      pageviews: 12,
      uniques: 4,
      series: [],
      paths: [%{path: "/login", pageviews: 8}],
      referrers: [%{referrer: "google.com", pageviews: 3}],
      utm: [%{source: "google", medium: "cpc", campaign: "a", pageviews: 2}],
      stale: false
    })

    {:ok, view, html} = live(conn, ~p"/apps/#{app.id}?tab=analytics")
    assert html =~ "12"
    assert html =~ "/login"
    assert html =~ "hash per UTC day"
    assert has_element?(view, "#analytics-inject-toggle")
  after
    Application.delete_env(:cleat_deploy, :analytics_app_stub)
  end

  test "toggle persists analytics_inject", %{conn: conn, scope: scope, server: server} do
    app = TenancyFixtures.app_fixture(scope, server, %{runtime: "static", slug: "memo-t"})
    {:ok, view, _} = live(conn, ~p"/apps/#{app.id}?tab=analytics")
    view |> element("#analytics-inject-toggle") |> render_click()
    assert Apps.get_app!(scope, app.id).analytics_inject
  end
end
