defmodule CleatDeployWeb.DashboardLiveTest do
  use CleatDeployWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias CleatDeploy.Deployments
  alias CleatDeploy.HetznerMock
  alias CleatDeploy.Settings
  alias CleatDeploy.TenancyFixtures
  alias CleatDeployWeb.UserAuth

  setup :register_and_log_in_user

  test "redirects when not logged in" do
    assert {:error, {:redirect, %{to: "/features"}}} = live(build_conn(), ~p"/")
  end

  test "renders dashboard when only remember-me cookie is present", %{user: user} do
    logged_in_conn =
      build_conn()
      |> Map.replace!(:secret_key_base, CleatDeployWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> fetch_cookies()
      |> UserAuth.log_in_user(user, %{"remember_me" => "true"})

    %{value: signed_token} = logged_in_conn.resp_cookies["_cleat_deploy_web_user_remember_me"]

    conn =
      logged_in_conn
      |> recycle()
      |> Map.replace!(:secret_key_base, CleatDeployWeb.Endpoint.config(:secret_key_base))
      |> put_req_cookie("_cleat_deploy_web_user_remember_me", signed_token)
      |> init_test_session(%{user_remember_me: true})

    refute get_session(conn, :user_token)

    {:ok, view, html} = live(conn, ~p"/")
    assert has_element?(view, "#dashboard")
    assert has_element?(view, "#theme-toggle")
    assert has_element?(view, "#app-shell")
    assert has_element?(view, "#app-sidebar")
    assert has_element?(view, "#app-sidebar-actions")
    assert has_element?(view, "#app-footer")
    assert has_element?(view, "#nav-dashboard")
    assert has_element?(view, "#nav-servers")
    assert has_element?(view, "#nav-apps")
    assert html =~ "Cleat"
  end

  test "renders dashboard when only user_id is present in session", %{user: user} do
    conn =
      build_conn()
      |> init_test_session(%{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#dashboard")
  end

  test "renders dashboard overview for tenant", %{conn: conn, scope: scope} do
    server =
      TenancyFixtures.server_fixture(scope, %{name: "lightsail-1", host_ip: "100.59.80.29"})

    TenancyFixtures.app_fixture(scope, server, %{
      name: "Trip Planner",
      slug: "trip-planner",
      github_repo: "puppe1990/trip-planner-ia-phx",
      host: "trip.gestaobem.com"
    })

    {:ok, view, html} = live(conn, ~p"/")
    assert has_element?(view, "#dashboard")
    assert html =~ "Configured apps"
    assert has_element?(view, "#metric-disk", "Disk used")
    assert has_element?(view, "#metric-memory", "Memory used")
    refute has_element?(view, "#dashboard-hero")
    refute html =~ "No Kubernetes Overheads"
    refute html =~ "HETZNER + LIGHTSAIL"
    assert has_element?(view, "#server-charts")
    assert has_element?(view, "#chart-cpu")
    assert has_element?(view, "#chart-network")
    assert has_element?(view, "#chart-runtimes")
    assert has_element?(view, "#chart-deploys")
    assert has_element?(view, "#chart-deploys-plot")
    assert has_element?(view, "#chart-deploys svg[preserveAspectRatio='none']")
    assert has_element?(view, "#chart-deploys-labels")
    refute has_element?(view, "#dashboard-apps-table")
    refute has_element?(view, "#apps-table")
    refute html =~ "Registered Phoenix Applications"
  end

  test "shows the active server without a switcher for a single server", %{
    conn: conn,
    scope: scope
  } do
    TenancyFixtures.server_fixture(scope, %{name: "gestaobem-cx33", instance_status: "running"})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#active-server-name", "gestaobem-cx33")
    assert has_element?(view, "#active-server-status", "running")
    refute has_element?(view, "#active-server-select")
  end

  test "switches the active server when the tenant has more than one", %{conn: conn, scope: scope} do
    running =
      TenancyFixtures.server_fixture(scope, %{name: "aaa-primary", instance_status: "running"})

    stopped =
      TenancyFixtures.server_fixture(scope, %{name: "zzz-secondary", instance_status: "stopped"})

    {:ok, view, _html} = live(conn, ~p"/")

    # Without a choice the running server is the active one.
    assert has_element?(view, "#active-server-select option[selected]", running.name)
    refute has_element?(view, "#active-server-name")

    view
    |> element("#active-server-select")
    |> render_change(%{"server_id" => to_string(stopped.id)})

    assert has_element?(view, "#active-server-select option[selected]", stopped.name)
    assert has_element?(view, "#active-server-status", "stopped")
    assert Settings.get_setting(scope).active_server_id == stopped.id

    # The choice survives a reload.
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "zzz-secondary"
  end

  test "ignores a server that is not part of the tenant", %{conn: conn, scope: scope} do
    mine = TenancyFixtures.server_fixture(scope, %{name: "mine", instance_status: "running"})
    TenancyFixtures.server_fixture(scope, %{name: "second", instance_status: "stopped"})
    other = TenancyFixtures.scope_fixture()
    foreign = TenancyFixtures.server_fixture(other, %{name: "foreign"})

    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> element("#active-server-select")
      |> render_change(%{"server_id" => to_string(foreign.id)})

    assert html =~ "Unknown server"
    assert has_element?(view, "#active-server-select option[selected]", mine.name)
    assert Settings.get_setting(scope).active_server_id == nil
  end

  test "configured apps and language bars follow the active server", %{
    conn: conn,
    scope: scope
  } do
    running =
      TenancyFixtures.server_fixture(scope, %{name: "aaa-primary", instance_status: "running"})

    stopped =
      TenancyFixtures.server_fixture(scope, %{name: "zzz-secondary", instance_status: "stopped"})

    TenancyFixtures.app_fixture(scope, running, %{
      runtime: "phoenix",
      slug: "on-primary",
      name: "Primary App"
    })

    TenancyFixtures.app_fixture(scope, stopped, %{
      runtime: "golang",
      slug: "on-secondary",
      name: "Secondary App"
    })

    TenancyFixtures.app_fixture(scope, stopped, %{
      runtime: "node",
      slug: "js-secondary",
      name: "JS App"
    })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#metric-apps", "1")
    assert has_element?(view, "#chart-runtimes", "1 registered on this server")

    view
    |> element("#active-server-select")
    |> render_change(%{"server_id" => to_string(stopped.id)})

    assert has_element?(view, "#metric-apps", "2")
    assert has_element?(view, "#chart-runtimes", "2 registered on this server")
  end

  test "deploy chart hover points skip 0/0 copy on empty days", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    points = chart_points(html, "chart-deploys-plot")
    assert length(points) == 14

    for point <- points do
      refute "0 success" in point["lines"]
      refute "0 failed" in point["lines"]
      assert point["lines"] == ["No deploys"]
    end
  end

  test "deploy chart hover points show counts on days with deploys", %{
    conn: conn,
    scope: scope
  } do
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    {:ok, queued} = Deployments.create_deployment(app, %{git_sha: "ok"})
    {:ok, running} = Deployments.mark_running(queued)
    {:ok, _} = Deployments.mark_success(running, "ok")

    {:ok, _view, html} = live(conn, ~p"/")
    points = chart_points(html, "chart-deploys-plot")
    today = Date.utc_today() |> Date.to_iso8601()
    match = Enum.find(points, &(&1["label"] == today))

    assert match
    assert "1 success" in match["lines"]
    assert "0 failed" in match["lines"]
  end

  test "plots hetzner cpu samples on the dashboard", %{conn: conn, scope: scope} do
    TenancyFixtures.server_fixture(scope, %{
      name: "gestaobem-cx33",
      provider: "hetzner",
      region: "fsn1",
      aws_instance_name: "gestaobem-cx33",
      bundle_name: "CX33",
      cpu_count: 4,
      ram_mb: 8192,
      disk_gb: 80,
      instance_status: "running"
    })

    stub(HetznerMock, :get_metrics, fn "fsn1", "gestaobem-cx33", _start, _end ->
      {:ok,
       %{
         cpu: [%{t: 1, v: 8.0}, %{t: 2, v: 21.5}, %{t: 3, v: 14.0}],
         network_in: [%{t: 1, v: 1_000.0}, %{t: 2, v: 2_000.0}, %{t: 3, v: 1_500.0}],
         network_out: [%{t: 1, v: 500.0}, %{t: 2, v: 800.0}, %{t: 3, v: 600.0}]
       }}
    end)

    {:ok, view, html} = live(conn, ~p"/")
    assert has_element?(view, "#chart-cpu")
    assert has_element?(view, "#chart-cpu-plot")
    assert has_element?(view, "#chart-network-plot")
    assert html =~ "gestaobem-cx33"
    assert html =~ "CX33"
    rendered = render(view)
    assert rendered =~ "14.0%"
    assert rendered =~ "21.5%"
    assert rendered =~ "data-points"
    assert has_element?(view, "#chart-cpu-current", "14.0%")
    refute render(view) =~ "Live · 100% = 1 vCPU"
  end

  test "live tick keeps hetzner current for a remote server", %{conn: conn, scope: scope} do
    TenancyFixtures.server_fixture(scope, %{
      name: "gestaobem-cx33",
      provider: "hetzner",
      region: "fsn1",
      aws_instance_name: "gestaobem-cx33",
      host_ip: "10.0.0.1",
      cpu_count: 4,
      instance_status: "running"
    })

    stub(HetznerMock, :get_metrics, fn "fsn1", "gestaobem-cx33", _start, _end ->
      {:ok,
       %{
         cpu: [%{t: 1, v: 8.0}, %{t: 2, v: 14.0}],
         network_in: [%{t: 1, v: 1_000.0}, %{t: 2, v: 1_500.0}],
         network_out: [%{t: 1, v: 500.0}, %{t: 2, v: 600.0}]
       }}
    end)

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#chart-cpu-current", "14.0%")

    send(view.pid, :tick_live)
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#chart-cpu-current", "14.0%")

    send(view.pid, :tick_hetzner)
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#chart-cpu")
    assert has_element?(view, "#chart-cpu-current", "14.0%")
  end

  test "does not show other tenant apps", %{conn: conn, scope: scope} do
    other = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(other)

    TenancyFixtures.app_fixture(other, server, %{
      name: "Secret App",
      slug: "secret",
      github_repo: "other/secret",
      host: "secret.example.com"
    })

    {:ok, view, _html} = live(conn, ~p"/")
    refute render(view) =~ "Secret App"
    assert scope.tenant.id != other.tenant.id
  end

  defp chart_points(html, id) do
    {:ok, regex} = Regex.compile(~s/id="#{id}"[^>]*data-points="([^"]+)"/)
    [_, encoded] = Regex.run(regex, html)
    encoded |> String.replace("&quot;", "\"") |> Jason.decode!()
  end
end
