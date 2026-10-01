defmodule CleatDeployWeb.SignalsLiveTest do
  use CleatDeployWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Observability.LogEvent
  alias CleatDeploy.Repo
  alias CleatDeploy.Signals
  alias CleatDeploy.TenancyFixtures

  setup :register_and_log_in_user

  test "redirects when not logged in" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/signals")
  end

  test "renders the Saúde overview and nav", %{conn: conn, scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)

    {:ok, view, _html} = live(conn, ~p"/signals")

    assert has_element?(view, "#nav-signals")
    assert has_element?(view, "#nav-signals-mobile")
    assert has_element?(view, "#signals-overview")
    assert has_element?(view, "#signals-health-table")
    assert has_element?(view, "#signals-status-#{app.slug}", "saudável")
    assert has_element?(view, "#signals-alerts")
    refute has_element?(view, "#signals-detail")
  end

  test "flags a degraded app and opens the incident detail", %{conn: conn, scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    now = DateTime.utc_now(:second)

    for _ <- 1..6 do
      insert_event(scope, server, app, %{
        severity: "err",
        occurred_at: DateTime.add(now, -30, :second)
      })
    end

    {:ok, view, _html} = live(conn, ~p"/signals")

    assert has_element?(view, "#signals-status-#{app.slug}", "degradada")

    view
    |> element("#signals-app-link-#{app.slug}")
    |> render_click()

    assert_patch(view, ~p"/signals?app=#{app.slug}")
    assert has_element?(view, "#signals-detail")
    assert has_element?(view, "#chart-signals-errors")
    assert has_element?(view, "#signals-timeline")
  end

  test "acks a firing alert from the Saúde page", %{conn: conn, scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    now = DateTime.utc_now(:second)

    for _ <- 1..6 do
      insert_event(scope, server, app, %{
        severity: "err",
        occurred_at: DateTime.add(now, -30, :second)
      })
    end

    {:ok, [alert]} = Signals.evaluate_alerts(scope, now: now)
    {:ok, view, _html} = live(conn, ~p"/signals")

    assert has_element?(view, "#signals-alert-#{alert.id}")
    assert has_element?(view, "#signals-ack-#{alert.id}")

    view
    |> element("#signals-ack-#{alert.id}")
    |> render_click()

    refute has_element?(view, "#signals-ack-#{alert.id}")
    assert has_element?(view, "#signals-alert-#{alert.id}")
  end

  defp insert_event(scope, server, app, attrs) do
    defaults = %{
      tenant_id: scope.tenant.id,
      app_id: app.id,
      server_id: server.id,
      source: "app",
      unit: app.systemd_unit || App.default_systemd_unit(app.slug, app.runtime || "phoenix"),
      cursor: "cursor-#{System.unique_integer([:positive])}",
      severity: "info",
      message: "hello",
      occurred_at: DateTime.utc_now(:second)
    }

    Repo.insert!(struct!(LogEvent, Map.merge(defaults, attrs)))
  end
end
