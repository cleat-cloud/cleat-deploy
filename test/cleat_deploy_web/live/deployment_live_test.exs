defmodule CleatDeployWeb.DeploymentLiveTest do
  use CleatDeployWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CleatDeploy.Deployments
  alias CleatDeploy.TenancyFixtures

  # VerifiedRoutes cannot compile ~p"/deployments" until the router grows that
  # path. Tests talk to the URL as a string so they fail for the missing feature,
  # not a compile error.
  @index "/deployments"

  setup :register_and_log_in_user

  test "redirects when not logged in" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), @index)
  end

  test "lists newest deploys across apps", %{conn: conn, scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    trip = TenancyFixtures.app_fixture(scope, server, %{name: "Trip Planner"})

    purple =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "Purple Stock",
        slug: "new-lp",
        host: "www.purplestock.com.br"
      })

    {:ok, older} = Deployments.create_deployment(trip, %{git_sha: "aaa111", git_ref: "main"})
    {:ok, newer} = Deployments.create_deployment(purple, %{git_sha: "bbb222"})

    {:ok, view, html} = live(conn, @index)

    assert has_element?(view, "#nav-deployments")
    assert has_element?(view, "#nav-deployments-mobile")
    assert has_element?(view, "#deployments-table")
    assert has_element?(view, "#deployments-#{newer.id}", "Purple Stock")
    assert has_element?(view, "#deployments-#{older.id}", "Trip Planner")
    assert html =~ "bbb222"
    assert html =~ "aaa111"
    assert html =~ "main"
    refute has_element?(view, "#deployments-empty")
    refute html =~ "View log"
  end

  test "hides deploys from another tenant", %{conn: conn, scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    {:ok, ours} = Deployments.create_deployment(app, %{git_sha: "ours-sha"})

    other_scope = TenancyFixtures.scope_fixture()
    other_server = TenancyFixtures.server_fixture(other_scope)
    other_app = TenancyFixtures.app_fixture(other_scope, other_server, %{name: "Foreign App"})
    {:ok, theirs} = Deployments.create_deployment(other_app, %{git_sha: "theirs-sha"})

    {:ok, view, html} = live(conn, @index)

    assert has_element?(view, "#deployments-#{ours.id}")
    refute has_element?(view, "#deployments-#{theirs.id}")
    refute html =~ "Foreign App"
    refute html =~ "theirs-sha"
  end

  test "shows an empty state when the tenant has no deploys", %{conn: conn} do
    {:ok, view, _html} = live(conn, @index)

    assert has_element?(view, "#deployments-empty")
    refute has_element?(view, "#deployments-filter-empty")
    refute has_element?(view, "#deployments-pagination")
  end

  test "applies query and status filters from the URL", %{conn: conn, scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    trip = TenancyFixtures.app_fixture(scope, server, %{name: "Trip Planner"})

    purple =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "Purple Stock",
        slug: "new-lp",
        host: "www.purplestock.com.br"
      })

    {:ok, queued} = Deployments.create_deployment(trip, %{git_sha: "trip-q"})
    {:ok, failed} = Deployments.create_deployment(purple, %{git_sha: "lp-fail"})
    {:ok, failed} = Deployments.mark_failed(failed, "boom")

    {:ok, view, _html} = live(conn, @index <> "?query=purple")
    assert has_element?(view, "#deployments-#{failed.id}")
    refute has_element?(view, "#deployments-#{queued.id}")

    {:ok, view, _html} = live(conn, @index <> "?status=failed")
    assert has_element?(view, "#deployments-#{failed.id}")
    refute has_element?(view, "#deployments-#{queued.id}")
  end

  test "status chips and search patch the URL", %{conn: conn, scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server, %{slug: "trip-planner"})
    {:ok, _} = Deployments.create_deployment(app, %{git_sha: "sha-q"})

    {:ok, view, _html} = live(conn, @index)

    view |> element("#deployments-filter-failed") |> render_click()
    assert_patch(view, @index <> "?status=failed")

    view |> element("#deployments-filter-all") |> render_click()
    assert_patch(view, @index)

    view |> form("#deployments-filter", %{query: "trip-planner"}) |> render_change()
    assert_patch(view, @index <> "?query=trip-planner")
  end

  test "shows a no-match empty state for a filter", %{conn: conn, scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    {:ok, _} = Deployments.create_deployment(app, %{git_sha: "sha-q"})

    {:ok, view, _html} = live(conn, @index <> "?query=does-not-match")

    assert has_element?(view, "#deployments-filter-empty")
    refute has_element?(view, "#deployments-empty")
  end

  test "app name opens that app's deploy history", %{conn: conn, scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server, %{name: "Trip Planner"})
    {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "nav-sha"})

    {:ok, view, _html} = live(conn, @index)

    assert {:error, {:live_redirect, %{to: path}}} =
             view |> element("#deployment-#{deployment.id}-app") |> render_click()

    assert path == "/apps/#{app.id}/deployments"
  end

  test "paginates tenant deploys from the URL", %{conn: conn, scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)

    deployments =
      for i <- 1..11 do
        {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "sha-#{i}"})
        deployment
      end

    oldest = List.first(deployments)
    newest = List.last(deployments)

    {:ok, view, _html} = live(conn, @index)

    assert has_element?(view, "#deployments-pagination")
    assert has_element?(view, "#deployments-page-status", "1-10 of 11")
    assert has_element?(view, "#deployments-#{newest.id}")
    refute has_element?(view, "#deployments-#{oldest.id}")

    view |> element("#deployments-page-next") |> render_click()
    assert_patch(view, @index <> "?page=2")
    assert has_element?(view, "#deployments-#{oldest.id}")
    refute has_element?(view, "#deployments-#{newest.id}")

    {:ok, view, _html} = live(conn, @index <> "?page=2")
    assert has_element?(view, "#deployments-page-status", "11-11 of 11")
    assert has_element?(view, "#deployments-#{oldest.id}")
  end

  test "polls the tenant list for a new deploy", %{conn: conn, scope: scope} do
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)

    {:ok, view, _html} = live(conn, @index)
    assert has_element?(view, "#deployments-empty")

    {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "poll-sha"})
    refute has_element?(view, "#deployments-#{deployment.id}")

    send(view.pid, :poll_deployments)
    assert has_element?(view, "#deployments-#{deployment.id}", "poll-sha")
  end
end
