defmodule CleatDeployWeb.SignalsLiveTest do
  use CleatDeployWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Observability.LogEvent
  alias CleatDeploy.Repo
  alias CleatDeploy.Signals
  alias CleatDeploy.Signals.Traces
  alias CleatDeploy.TenancyFixtures

  @trace_id "5b8aa5a2d2c872e8321cf37308d69df2"
  @root_span "051581bf3cb55c13"

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

  test "warns while the log collector is off", %{conn: conn, scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    TenancyFixtures.app_fixture(scope, server)

    {:ok, view, _html} = live(conn, ~p"/signals")

    assert has_element?(view, "#signals-ingest-banner", "Coletor de logs desligado")
  end

  test "warns when an enabled log collector stalls", %{conn: conn, scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)

    Application.put_env(:cleat_deploy, :log_collector_enabled, true)
    on_exit(fn -> Application.put_env(:cleat_deploy, :log_collector_enabled, false) end)

    {:ok, view, _html} = live(conn, ~p"/signals")

    assert has_element?(view, "#signals-ingest-banner", "Ingestão de logs parada")

    row = view |> element("#signals-app-#{app.slug}") |> render()
    assert row =~ "—"
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

  test "opens a waterfall and service map from an ingested trace", %{conn: conn, scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    {:ok, _} = Traces.set_sampling(scope, app, 1.0)
    {:ok, _} = Traces.ingest(scope, app, checkout_payload())

    {:ok, view, _html} = live(conn, ~p"/signals?app=#{app.slug}")

    assert has_element?(view, "#signals-traces")
    assert has_element?(view, "#signals-trace-#{@trace_id}")
    assert has_element?(view, "#signals-sampling-form")

    view
    |> element("#signals-trace-#{@trace_id}")
    |> render_click()

    assert_patch(view, ~p"/signals?app=#{app.slug}&trace_id=#{@trace_id}")
    assert has_element?(view, "#signals-waterfall")
    assert has_element?(view, "#signals-span-#{@root_span}")
    assert has_element?(view, "#signals-service-map")
  end

  test "jumps from a log line to the matching trace", %{conn: conn, scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    {:ok, _} = Traces.set_sampling(scope, app, 1.0)
    {:ok, _} = Traces.ingest(scope, app, checkout_payload())
    insert_event(scope, server, app, %{message: "failed trace_id=#{@trace_id}", severity: "err"})

    {:ok, view, _html} = live(conn, ~p"/signals?app=#{app.slug}")

    assert has_element?(view, "#signals-log-jump-#{@trace_id}")

    view
    |> element("#signals-log-jump-#{@trace_id}")
    |> render_click()

    assert_patch(view, ~p"/signals?app=#{app.slug}&trace_id=#{@trace_id}")
    assert has_element?(view, "#signals-waterfall")
  end

  test "saves per-app sampling from the Saúde page", %{conn: conn, scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)

    {:ok, view, _html} = live(conn, ~p"/signals?app=#{app.slug}")

    view
    |> form("#signals-sampling-form", sampling: %{rate: "1"})
    |> render_submit()

    assert Repo.get!(App, app.id).trace_sample_rate == 1.0
  end

  defp checkout_payload do
    %{
      "resourceSpans" => [
        %{
          "resource" => %{
            "attributes" => [
              %{"key" => "service.name", "value" => %{"stringValue" => "web"}}
            ]
          },
          "scopeSpans" => [
            %{
              "spans" => [
                %{
                  "traceId" => @trace_id,
                  "spanId" => @root_span,
                  "parentSpanId" => "",
                  "name" => "GET /checkout",
                  "kind" => 2,
                  "startTimeUnixNano" => "1544712660000000000",
                  "endTimeUnixNano" => "1544712661000000000",
                  "status" => %{"code" => 1},
                  "attributes" => []
                }
              ]
            }
          ]
        }
      ]
    }
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
