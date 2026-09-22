defmodule CleatDeployWeb.AppLiveTest do
  use CleatDeployWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias CleatDeploy.{Apps, Deployments}
  alias CleatDeploy.RuntimeLogsFixtures
  alias CleatDeploy.TenancyFixtures

  setup :register_and_log_in_user
  setup :verify_on_exit!

  setup %{scope: scope} do
    RuntimeLogsFixtures.stub_success()

    server = TenancyFixtures.server_fixture(scope)
    %{server: server}
  end

  test "renders plug-and-play new app form", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/apps/new")

    assert has_element?(view, "#app-form")
    assert html =~ "Register application"
    assert html =~ "Pick a GitHub repository"
    refute html =~ "Systemd unit"
  end

  test "auto-fills profile when github repo is selected", %{conn: conn, server: server} do
    {:ok, view, _html} = live(conn, ~p"/apps/new")

    html =
      view
      |> form("#app-form", app: %{github_repo: "puppe1990/trip-planner-ia-phx"})
      |> render_change()

    assert html =~ "app-provision-preview"
    assert html =~ "Trip Planner"
    assert html =~ "trip.gestaobem.com"
    assert has_element?(view, "#save-app-button")

    view
    |> form("#app-form", app: %{github_repo: "puppe1990/trip-planner-ia-phx"})
    |> render_submit()

    app = Apps.get_app_by_repo("puppe1990/trip-planner-ia-phx")
    assert app.name == "Trip Planner"
    assert app.host == "trip.gestaobem.com"
    assert app.server_id == server.id
  end

  test "lists apps", %{conn: conn, scope: scope, server: server} do
    TenancyFixtures.app_fixture(scope, server, %{
      name: "Trip Planner",
      slug: "trip-planner",
      github_repo: "puppe1990/trip-planner-ia-phx",
      host: "trip.gestaobem.com"
    })

    {:ok, view, _html} = live(conn, ~p"/apps")
    assert has_element?(view, "#apps-list")
    assert has_element?(view, "#apps-table")
    assert has_element?(view, "#apps-table th", "Main language")
    assert has_element?(view, "#apps-table th", "RAM")
    assert has_element?(view, "#apps-table th", "CPU")
    assert has_element?(view, "#apps-table th", "Disk")
    assert render(view) =~ "Trip Planner"
  end

  test "paginates the apps list 10 per page", %{conn: conn, scope: scope, server: server} do
    for n <- 1..12 do
      label = String.pad_leading(Integer.to_string(n), 2, "0")

      TenancyFixtures.app_fixture(scope, server, %{
        name: "App #{label}",
        slug: "app-#{n}",
        github_repo: "owner/repo-#{n}",
        host: "app-#{n}.example.com"
      })
    end

    {:ok, view, html} = live(conn, ~p"/apps")

    assert html =~ "App 01"
    assert html =~ "App 10"
    refute html =~ "App 11"
    assert has_element?(view, "#apps-pagination")
    assert has_element?(view, "#apps-page-status", "1-10 of 12")
    assert has_element?(view, "#apps-page-first[disabled]")
    refute has_element?(view, "#apps-page-last[disabled]")

    html = view |> element("#apps-page-next") |> render_click()

    assert html =~ "App 11"
    assert html =~ "App 12"
    refute html =~ "App 01"
    assert has_element?(view, "#apps-page-status", "11-12 of 12")
    assert has_element?(view, "#apps-page-next[disabled]")
    refute has_element?(view, "#apps-page-first[disabled]")
    assert has_element?(view, "#apps-page-last[disabled]")

    view |> element("#apps-page-first") |> render_click()

    assert has_element?(view, "#apps-page-status", "1-10 of 12")
    assert has_element?(view, "#apps-page-first[disabled]")

    view |> element("#apps-page-last") |> render_click()

    assert has_element?(view, "#apps-page-status", "11-12 of 12")
    assert has_element?(view, "#apps-page-last[disabled]")
  end

  test "lists each app's main language", %{conn: conn, scope: scope, server: server} do
    phoenix_app =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "Trip Planner",
        slug: "trip-planner",
        github_repo: "puppe1990/trip-planner-ia-phx",
        host: "trip.gestaobem.com",
        runtime: "phoenix"
      })

    go_app =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "Atelie",
        slug: "atelie",
        github_repo: "puppe1990/atelie",
        host: "atelie.gestaobem.com",
        runtime: "golang"
      })

    {:ok, view, _html} = live(conn, ~p"/apps")

    assert has_element?(view, "#apps-table")
    assert has_element?(view, "#apps-table th", "Main language")
    assert has_element?(view, "#app-#{phoenix_app.id}-language", "Elixir")
    assert has_element?(view, "#app-#{go_app.id}-language", "Go")
    wait_for(view, fn -> has_element?(view, "#app-#{phoenix_app.id}-ram", "163 MB") end)
    assert has_element?(view, "#app-#{phoenix_app.id}-ram", "163 MB")
    assert has_element?(view, "#app-#{phoenix_app.id}-cpu", "2.8%")
    assert has_element?(view, "#app-#{phoenix_app.id}-disk", "510 MB")
    assert has_element?(view, "#app-#{go_app.id}-ram", "173 MB")
    assert has_element?(view, "#app-#{go_app.id}-cpu", "4.5%")
    assert has_element?(view, "#app-#{go_app.id}-disk", "500 MB")
  end

  test "filters registered apps by search query", %{conn: conn, scope: scope, server: server} do
    TenancyFixtures.app_fixture(scope, server, %{
      name: "Atelie",
      slug: "atelie",
      github_repo: "puppe1990/atelie",
      host: "atelie.gestaobem.com"
    })

    TenancyFixtures.app_fixture(scope, server, %{
      name: "Vexo",
      slug: "vexo",
      github_repo: "puppe1990/vexo",
      host: "vexo.gestaobem.com"
    })

    {:ok, view, _html} = live(conn, ~p"/apps")
    assert has_element?(view, "#apps-filter")
    assert render(view) =~ "Atelie"
    assert render(view) =~ "Vexo"

    view
    |> form("#apps-filter", %{query: "vexo"})
    |> render_change()

    html = render(view)
    assert html =~ "Vexo"
    refute html =~ "Atelie"
  end

  test "filters registered apps by language", %{conn: conn, scope: scope, server: server} do
    TenancyFixtures.app_fixture(scope, server, %{
      name: "Trip Planner",
      slug: "trip-planner",
      github_repo: "puppe1990/trip-planner-ia-phx",
      host: "trip.gestaobem.com",
      runtime: "phoenix"
    })

    TenancyFixtures.app_fixture(scope, server, %{
      name: "Atelie",
      slug: "atelie",
      github_repo: "puppe1990/atelie",
      host: "atelie.gestaobem.com",
      runtime: "golang"
    })

    {:ok, view, _html} = live(conn, ~p"/apps")
    view |> element("#apps-filter-golang") |> render_click()

    html = render(view)
    assert html =~ "Atelie"
    refute html =~ "Trip Planner"

    view |> element("#apps-filter-phoenix") |> render_click()
    html = render(view)
    assert html =~ "Trip Planner"
    refute html =~ "Atelie"
  end

  test "filters static apps separately from phoenix", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    static_app =
      TenancyFixtures.app_fixture(scope, server, %{runtime: "static", github_repo: ""})

    phx_app = TenancyFixtures.app_fixture(scope, server, %{runtime: "phoenix"})

    {:ok, view, _html} = live(conn, ~p"/apps")

    view |> element("#apps-filter-static") |> render_click()
    rendered = render(view)
    assert rendered =~ static_app.host
    refute rendered =~ phx_app.host
    assert_patch(view, ~p"/apps?runtime=static")

    view |> element("#apps-filter-phoenix") |> render_click()
    rendered = render(view)
    assert rendered =~ phx_app.host
    refute rendered =~ static_app.host
  end

  test "hides the deploy action for static apps", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    static_app =
      TenancyFixtures.app_fixture(scope, server, %{runtime: "static", github_repo: ""})

    phx_app = TenancyFixtures.app_fixture(scope, server, %{runtime: "phoenix"})

    {:ok, view, _html} = live(conn, ~p"/apps")

    refute has_element?(view, "#app-#{static_app.id}-deploy")
    assert has_element?(view, "#app-#{phx_app.id}-deploy")
  end

  test "applies filters from the URL", %{conn: conn, scope: scope, server: server} do
    go_app = TenancyFixtures.app_fixture(scope, server, %{runtime: "golang"})
    phx_app = TenancyFixtures.app_fixture(scope, server, %{runtime: "phoenix"})

    {:ok, view, _html} = live(conn, ~p"/apps?runtime=golang")
    rendered = render(view)
    assert rendered =~ go_app.host
    refute rendered =~ phx_app.host

    {:ok, view, _html} = live(conn, ~p"/apps?query=#{phx_app.slug}")
    rendered = render(view)
    assert rendered =~ phx_app.host
    refute rendered =~ go_app.host
  end

  test "reflects filters in the URL", %{conn: conn, scope: scope, server: server} do
    app = TenancyFixtures.app_fixture(scope, server, %{runtime: "golang"})

    {:ok, view, _html} = live(conn, ~p"/apps")

    view |> element("#apps-filter-golang") |> render_click()
    assert_patch(view, ~p"/apps?runtime=golang")

    view |> element("#apps-filter-all") |> render_click()
    assert_patch(view, ~p"/apps")

    view |> form("#apps-filter", %{query: app.slug}) |> render_change()
    assert_patch(view, ~p"/apps?query=#{app.slug}")
  end

  test "deletes an app from the list after slug confirmation", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "Cifra",
        slug: "cifra",
        github_repo: "puppe1990/cifra-finops",
        host: "finops.gestaobem.com"
      })

    {:ok, view, _html} = live(conn, ~p"/apps")

    refute has_element?(view, "#apps-delete-modal")

    view |> element("#app-#{app.id}-delete") |> render_click()
    assert has_element?(view, "#apps-delete-modal")
    assert has_element?(view, "#apps-delete-button[disabled]")

    view |> element("#apps-keep-button") |> render_click()
    refute has_element?(view, "#apps-delete-modal")
    assert Apps.get_app!(scope, app.id)

    view |> element("#app-#{app.id}-delete") |> render_click()

    html =
      view
      |> form("#apps-delete-form", delete: %{confirm: "wrong"})
      |> render_submit()

    assert html =~ "Type cifra to confirm"
    assert Apps.get_app_by_repo("puppe1990/cifra-finops")

    view |> form("#apps-delete-form", delete: %{confirm: "cifra"}) |> render_change()
    assert has_element?(view, "#apps-delete-button:not([disabled])")

    html =
      view
      |> form("#apps-delete-form", delete: %{confirm: "cifra"})
      |> render_submit()

    assert html =~ "was deleted"
    refute has_element?(view, "#apps-delete-modal")
    refute Apps.get_app_by_repo("puppe1990/cifra-finops")
  end

  test "sorts registered apps when a column header is clicked", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    TenancyFixtures.app_fixture(scope, server, %{
      name: "Atelie",
      slug: "atelie",
      github_repo: "puppe1990/atelie",
      host: "atelie.gestaobem.com"
    })

    TenancyFixtures.app_fixture(scope, server, %{
      name: "Vexo",
      slug: "vexo",
      github_repo: "puppe1990/vexo",
      host: "vexo.gestaobem.com"
    })

    {:ok, view, html} = live(conn, ~p"/apps")
    assert has_element?(view, "#sort-apps-name")
    assert app_name_order(html) == ["Atelie", "Vexo"]

    html = view |> element("#sort-apps-name") |> render_click()
    assert app_name_order(html) == ["Vexo", "Atelie"]
  end

  test "redirects app show to deployments page", %{conn: conn, scope: scope, server: server} do
    app = TenancyFixtures.app_fixture(scope, server)

    assert {:error, {:live_redirect, %{to: path}}} = live(conn, ~p"/apps/#{app.id}")
    assert path == ~p"/apps/#{app.id}/deployments"
  end

  test "shows app with deployments and deploy button", %{conn: conn, scope: scope, server: server} do
    app =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "Trip Planner",
        slug: "trip-planner",
        github_repo: "puppe1990/trip-planner-ia-phx",
        host: "trip.gestaobem.com"
      })

    {:ok, _deployment} = Deployments.create_deployment(app, %{git_sha: "abc123"})

    {:ok, view, html} = live(conn, ~p"/apps/#{app.id}/deployments")
    assert has_element?(view, "#deploy-button")
    assert has_element?(view, "#app-detail-tabs")
    assert has_element?(view, "#deployments-history")
    assert html =~ "Deployments Version History"
    assert html =~ "abc123"
    wait_for(view, fn -> has_element?(view, "#app-memory-tile", "163 MB") end)
    assert has_element?(view, "#app-memory-tile", "163 MB")
    assert has_element?(view, "#app-cpu-tile", "2.8%")
    assert has_element?(view, "#app-disk-tile", "510 MB")
    assert has_element?(view, "#app-status-tile", "Active")
    assert has_element?(view, "#app-runtime-badge", "PHX")
  end

  test "shows GO badge for golang apps instead of PHX", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "Cifra",
        slug: "cifra",
        github_repo: "puppe1990/cifra-finops",
        host: "finops.gestaobem.com",
        runtime: "golang"
      })

    {:ok, view, html} = live(conn, ~p"/apps/#{app.id}/deployments")

    assert html =~ "Cifra"
    assert has_element?(view, "#app-runtime-badge", "GO")
    refute has_element?(view, "#app-runtime-badge", "PHX")
  end

  test "links the repository to GitHub in the header and hero", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "Cifra",
        slug: "cifra",
        github_repo: "puppe1990/cifra-finops",
        host: "finops.gestaobem.com"
      })

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}/deployments")

    for selector <- ["#app-repo-mapping", "#app-repo-hero"] do
      assert has_element?(view, selector, "puppe1990/cifra-finops")

      assert has_element?(view, ~s(#{selector}[target="_blank"][rel="noopener noreferrer"]))

      assert has_element?(
               view,
               ~s(#{selector}[href="https://github.com/puppe1990/cifra-finops"])
             )
    end
  end

  test "links the live system host in the app hero", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "Atelie",
        slug: "atelie",
        github_repo: "puppe1990/atelie",
        host: "atelie.gestaobem.com"
      })

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}/deployments")

    assert has_element?(view, "#app-host-hero", "atelie.gestaobem.com")
    assert has_element?(view, ~s(#app-host-hero[target="_blank"][rel="noopener noreferrer"]))
    assert has_element?(view, ~s(#app-host-hero[href="https://atelie.gestaobem.com"]))
  end

  test "switches app detail tabs", %{conn: conn, scope: scope, server: server} do
    app = TenancyFixtures.app_fixture(scope, server)

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}/deployments")
    assert has_element?(view, "#app-detail-tab-deployments")
    assert has_element?(view, "#app-deployments")

    {:ok, view, html} = live(conn, ~p"/apps/#{app.id}?tab=environment")

    assert html =~ "Environment variables"
    assert has_element?(view, "#app-env-vars")
    refute has_element?(view, "#app-webhook")

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}?tab=webhook")
    assert has_element?(view, "#app-webhook")
    assert has_element?(view, "#deploy-branch-form")
    refute has_element?(view, "#app-env-vars")

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}?tab=logs")
    assert has_element?(view, "#app-detail-tab-logs")
    assert has_element?(view, "#app-runtime-logs")
    assert has_element?(view, "#refresh-app-logs")

    wait_for(view, fn -> render(view) =~ "2026-09-06T12:00:00Z" end)
    assert render(view) =~ "2026-09-06T12:00:00Z"

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}?tab=danger")
    assert has_element?(view, "#app-detail-tab-danger")
    assert has_element?(view, "#app-danger-zone")
    assert has_element?(view, "#delete-app-form")
    refute has_element?(view, "#app-webhook")
  end

  test "edits the deploy branch from the webhook tab", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "PratoAI",
        slug: "prato-ai",
        github_repo: "gestao-bem/prato-ai-#{System.unique_integer()}",
        branch: "deploy-cleat",
        host: "pratoai.gestaobem.com"
      })

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}?tab=webhook")
    assert has_element?(view, "#deploy-branch-form")
    assert has_element?(view, "#app-deploy-branch-tile", "deploy-cleat")

    html =
      view
      |> form("#deploy-branch-form", app: %{branch: "main"})
      |> render_submit()

    assert html =~ "Auto-deploy now listens to main"
    assert has_element?(view, "#app-deploy-branch-tile", "main")
    assert Apps.get_app!(scope, app.id).branch == "main"
  end

  test "shows an error when the deploy branch is blank", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app = TenancyFixtures.app_fixture(scope, server)

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}?tab=webhook")

    html =
      view
      |> form("#deploy-branch-form", app: %{branch: "   "})
      |> render_submit()

    assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    assert Apps.get_app!(scope, app.id).branch == "main"
  end

  test "danger zone deletes the app after slug confirmation", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "Cifra",
        slug: "cifra",
        github_repo: "puppe1990/cifra-finops",
        host: "finops.gestaobem.com"
      })

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}?tab=danger")
    assert has_element?(view, "#delete-app-button[disabled]")

    view
    |> form("#delete-app-form", delete: %{confirm: "wrong"})
    |> render_change()

    assert has_element?(view, "#delete-app-button[disabled]")

    html =
      view
      |> form("#delete-app-form", delete: %{confirm: "wrong"})
      |> render_submit()

    assert html =~ "Type cifra to confirm"
    assert Apps.get_app_by_repo("puppe1990/cifra-finops")

    view
    |> form("#delete-app-form", delete: %{confirm: "cifra"})
    |> render_change()

    assert has_element?(view, "#delete-app-button:not([disabled])")

    {:ok, index_view, html} =
      view
      |> form("#delete-app-form", delete: %{confirm: "cifra"})
      |> render_submit()
      |> follow_redirect(conn, ~p"/apps")

    assert html =~ "was deleted"
    assert has_element?(index_view, "#apps-list")
    refute Apps.get_app_by_repo("puppe1990/cifra-finops")
  end

  test "keeps each journal line on a single numbered row", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app = TenancyFixtures.app_fixture(scope, server)

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}?tab=logs")

    wait_for(view, fn -> has_element?(view, "#log-line-1") end)

    assert has_element?(view, "#log-line-1")
    assert has_element?(view, "#log-line-2")
    refute has_element?(view, "#log-line-3")
    assert has_element?(view, "#log-line-2", "duration_ms")
  end

  test "shows environment variables with masked secrets", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app = TenancyFixtures.app_fixture(scope, server)

    {:ok, _} = Apps.put_env_var(app, "PORT", "4003")
    {:ok, _} = Apps.put_env_var(app, "SECRET_KEY_BASE", "super-secret")

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}?tab=environment")
    html = render(view)

    assert html =~ "Environment variables"
    assert has_element?(view, "#app-env-vars")
    assert has_element?(view, "#env-var-PORT")
    assert has_element?(view, "#env-var-SECRET_KEY_BASE")
    assert html =~ "4003"
    refute html =~ "super-secret"

    view |> element("button", "Reveal secrets") |> render_click()
    assert render(view) =~ "super-secret"
  end

  test "queues manual deploy", %{conn: conn, scope: scope, server: server} do
    app = TenancyFixtures.app_fixture(scope, server)

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}/deployments")
    view |> element("#deploy-button") |> render_click()

    assert_enqueued(worker: CleatDeploy.Workers.DeployWorker)
    assert render(view) =~ "Deploy queued"
  end

  test "cancels the active deploy from the deployments page", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app = TenancyFixtures.app_fixture(scope, server)

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}/deployments")
    refute has_element?(view, "#cancel-deploy-button")

    {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "cancel-me"})
    {:ok, running} = Deployments.mark_running(deployment)

    assert has_element?(view, "#cancel-deploy-button")
    refute has_element?(view, "#cancel-deploy-modal")

    view |> element("#cancel-deploy-button") |> render_click()

    assert has_element?(view, "#cancel-deploy-modal")
    assert render(view) =~ "Cancel this deploy?"

    view |> element("#keep-deploy-button") |> render_click()

    refute has_element?(view, "#cancel-deploy-modal")
    assert Deployments.get_deployment!(running.id).status == :running

    view |> element("#cancel-deploy-button") |> render_click()
    view |> element("#confirm-cancel-deploy-button") |> render_click()

    assert render(view) =~ "Deploy ##{running.id} cancelled"
    assert Deployments.get_deployment!(running.id).status == :failed
    refute Deployments.deploying?(scope, app)
    refute has_element?(view, "#cancel-deploy-button")
    refute has_element?(view, "#cancel-deploy-modal")
  end

  test "cancels the active deploy from the app page", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app = TenancyFixtures.app_fixture(scope, server)
    {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "cancel-here"})
    {:ok, _queued} = Deployments.mark_running(deployment)

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}?tab=environment")
    assert has_element?(view, "#cancel-deploy-button")

    view |> element("#cancel-deploy-button") |> render_click()
    assert has_element?(view, "#cancel-deploy-modal")

    view |> element("#confirm-cancel-deploy-button") |> render_click()

    assert render(view) =~ "cancelled"
    assert Deployments.get_deployment!(deployment.id).status == :failed
    refute has_element?(view, "#cancel-deploy-button")
  end

  test "shows a deploy that starts while the page is open", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app = TenancyFixtures.app_fixture(scope, server)

    {:ok, view, html} = live(conn, ~p"/apps/#{app.id}/deployments")
    refute html =~ "webhook-sha"

    {:ok, deployment} =
      Deployments.create_deployment(app, %{git_sha: "webhook-sha", triggered_by: "github"})

    html = render(view)
    assert html =~ "webhook-sha"
    assert has_element?(view, "#deployments-#{deployment.id}")
    assert has_element?(view, "#deploy-button", "Build in progress")
  end

  test "updates deploy status without a page refresh", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app = TenancyFixtures.app_fixture(scope, server)
    {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "live-sha"})

    {:ok, view, html} = live(conn, ~p"/apps/#{app.id}/deployments")
    assert html =~ "queued"

    {:ok, running} = Deployments.mark_running(deployment)
    html = render(view)
    assert html =~ "running"
    assert has_element?(view, "#deployments-#{running.id}")
    assert has_element?(view, "#deploy-button", "Build in progress")

    {:ok, _success} = Deployments.mark_success(running, "deploy finished live")
    html = render(view)
    assert html =~ "success"
    assert html =~ "deploy finished live"
    refute has_element?(view, "#deploy-button", "Build in progress")
  end

  test "shows deploy duration in history", %{conn: conn, scope: scope, server: server} do
    app = TenancyFixtures.app_fixture(scope, server)

    {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "dur123"})

    {:ok, finished} =
      deployment
      |> Ecto.Changeset.change(%{
        status: :success,
        started_at: ~U[2026-06-29 10:00:00Z],
        finished_at: ~U[2026-06-29 10:01:30Z]
      })
      |> CleatDeploy.Repo.update()

    {:ok, view, html} = live(conn, ~p"/apps/#{app.id}/deployments")

    assert html =~ "1m 30s"
    assert has_element?(view, "#deployments-#{finished.id}")
  end

  test "views log from an older deployment", %{conn: conn, scope: scope, server: server} do
    app = TenancyFixtures.app_fixture(scope, server)

    {:ok, older} =
      Deployments.create_deployment(app, %{
        git_sha: "older-sha",
        log: "older deploy log line"
      })

    {:ok, older} =
      older
      |> Ecto.Changeset.change(%{
        status: :success,
        started_at: ~U[2026-06-29 09:00:00Z],
        finished_at: ~U[2026-06-29 09:01:00Z]
      })
      |> CleatDeploy.Repo.update()

    {:ok, newer} =
      Deployments.create_deployment(app, %{
        git_sha: "newer-sha",
        log: "newer deploy log line"
      })

    {:ok, newer} =
      newer
      |> Ecto.Changeset.change(%{
        status: :success,
        started_at: ~U[2026-06-29 10:00:00Z],
        finished_at: ~U[2026-06-29 10:02:00Z]
      })
      |> CleatDeploy.Repo.update()

    {:ok, view, html} = live(conn, ~p"/apps/#{app.id}/deployments")

    assert html =~ "newer deploy log line"
    refute html =~ "older deploy log line"
    assert has_element?(view, "#view-deploy-log-#{newer.id}[aria-pressed=true]")
    assert has_element?(view, "#view-deploy-log-#{older.id}[aria-pressed=false]")

    view |> element("#view-deploy-log-#{older.id}") |> render_click()

    html = render(view)
    assert html =~ "older deploy log line"
    assert has_element?(view, "#deploy-terminal-#{older.id}")
    refute has_element?(view, "#deploy-terminal-#{newer.id}")

    assert has_element?(view, "#view-deploy-log-#{older.id}[aria-pressed=true]")
    assert has_element?(view, "#view-deploy-log-#{newer.id}[aria-pressed=false]")
    assert render(view) =~ "Viewing deploy ##{older.id}"
  end

  test "hides history pagination when there are 10 or fewer deployments", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app = TenancyFixtures.app_fixture(scope, server)

    for i <- 1..10 do
      {:ok, _} = Deployments.create_deployment(app, %{git_sha: "sha-#{i}"})
    end

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}/deployments")
    refute has_element?(view, "#deployments-pagination")
  end

  test "paginates version history 10 per page", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app = TenancyFixtures.app_fixture(scope, server)

    deployments =
      for i <- 1..11 do
        {:ok, deployment} = Deployments.create_deployment(app, %{git_sha: "sha-#{i}"})
        deployment
      end

    oldest = List.first(deployments)
    newest = List.last(deployments)

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}/deployments")

    assert has_element?(view, "#deployments-pagination")
    assert has_element?(view, "#deployments-page-status", "1-10 of 11")
    assert has_element?(view, "#deployments-#{newest.id}")
    refute has_element?(view, "#deployments-#{oldest.id}")
    assert has_element?(view, "#deployments-page-prev[disabled]")
    refute has_element?(view, "#deployments-page-next[disabled]")
    assert has_element?(view, "#deployments-page-first[disabled]")
    refute has_element?(view, "#deployments-page-last[disabled]")

    view |> element("#deployments-page-next") |> render_click()

    assert has_element?(view, "#deployments-page-status", "11-11 of 11")
    assert has_element?(view, "#deployments-#{oldest.id}")
    refute has_element?(view, "#deployments-#{newest.id}")
    refute has_element?(view, "#deployments-page-prev[disabled]")
    assert has_element?(view, "#deployments-page-next[disabled]")
    assert has_element?(view, "#deployments-page-last[disabled]")

    view |> element("#deployments-page-first") |> render_click()

    assert has_element?(view, "#deployments-page-status", "1-10 of 11")
    assert has_element?(view, "#deployments-page-first[disabled]")

    view |> element("#deployments-page-last") |> render_click()

    assert has_element?(view, "#deployments-page-status", "11-11 of 11")
    assert has_element?(view, "#deployments-page-last[disabled]")

    view |> element("#deployments-page-prev") |> render_click()

    assert has_element?(view, "#deployments-page-status", "1-10 of 11")
    assert has_element?(view, "#deployments-#{newest.id}")
    refute has_element?(view, "#deployments-#{oldest.id}")
  end

  test "toggles auto sleep from the hero", %{conn: conn, scope: scope, server: server} do
    app =
      TenancyFixtures.app_fixture(scope, server, %{slug: "sleeper", host: "sleeper.example.com"})

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}?tab=environment")

    assert has_element?(view, "#app-idle-toggle[data-state=off]")
    assert has_element?(view, "#app-sleep-global-off")
    refute has_element?(view, "#idle-sleep-modal")
    refute Apps.get_app!(scope, app.id).idle_shutdown_enabled

    # Opens the confirmation; cancelling changes nothing.
    view |> element("#app-idle-toggle") |> render_click()

    assert has_element?(view, "#idle-sleep-modal")
    assert has_element?(view, "#idle-sleep-title", "Turn on auto sleep?")

    view |> element("#keep-idle-sleep-button") |> render_click()

    refute has_element?(view, "#idle-sleep-modal")
    refute Apps.get_app!(scope, app.id).idle_shutdown_enabled

    view |> element("#app-idle-toggle") |> render_click()
    html = view |> element("#confirm-idle-sleep-button") |> render_click()

    assert html =~ "Auto sleep on"
    assert has_element?(view, "#app-idle-toggle[data-state=on]")
    assert Apps.get_app!(scope, app.id).idle_shutdown_enabled
    refute has_element?(view, "#idle-sleep-modal")

    # Turning it off asks for confirmation too.
    view |> element("#app-idle-toggle") |> render_click()

    assert has_element?(view, "#idle-sleep-title", "Turn off auto sleep?")
    assert has_element?(view, "#confirm-idle-sleep-button", "Yes, turn it off")

    html = view |> element("#confirm-idle-sleep-button") |> render_click()

    assert html =~ "Auto sleep off"
    refute Apps.get_app!(scope, app.id).idle_shutdown_enabled
  end

  test "hibernates and wakes the app from the hero", %{conn: conn, scope: scope, server: server} do
    app =
      TenancyFixtures.app_fixture(scope, server, %{slug: "sleeper", host: "sleeper.example.com"})

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}/deployments")
    assert has_element?(view, "#hibernate-button", "Hibernate")
    refute has_element?(view, "#hibernate-modal")

    view |> element("#hibernate-button") |> render_click()

    assert has_element?(view, "#hibernate-modal")
    assert has_element?(view, "#hibernate-title", "Hibernate")
    assert has_element?(view, "#confirm-hibernate-button", "Yes, hibernate")

    html = view |> element("#keep-hibernate-button") |> render_click()
    refute has_element?(view, "#hibernate-modal")
    refute html =~ "hibernated"

    expect(CleatDeploy.Apps.RuntimeControlMock, :run, fn _subject, ["bash", "-c", script] ->
      assert script =~ "sudo systemctl stop"
      {:ok, "state=inactive\n"}
    end)

    view |> element("#hibernate-button") |> render_click()
    html = view |> element("#confirm-hibernate-button") |> render_click()

    assert html =~ "hibernated"
    refute has_element?(view, "#hibernate-modal")

    expect(CleatDeploy.Apps.RuntimeControlMock, :run, fn _subject, ["bash", "-c", script] ->
      assert script =~ "sudo systemctl start"
      {:ok, "state=active\n"}
    end)

    html = render_hook(view, "wake_app")
    assert html =~ "is starting"
  end

  test "the hibernate dialog says how the app actually comes back", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    # The flag alone arms nothing: only a deploy writes the wake agent in front
    # of the site, and that is what the dialog must say.
    flagged =
      TenancyFixtures.app_fixture(scope, server, %{slug: "flagged", host: "flagged.example.com"})

    {:ok, flagged} = Apps.update_app_settings(scope, flagged, %{"idle_shutdown_enabled" => true})

    {:ok, view, _html} = live(conn, ~p"/apps/#{flagged.id}/deployments")
    view |> element("#hibernate-button") |> render_click()

    assert has_element?(view, "#hibernate-modal", "only comes back with the Wake up button")

    armed =
      TenancyFixtures.app_fixture(scope, server, %{slug: "armed", host: "armed.example.com"})

    {:ok, armed} = Apps.record_deploy_manifest(armed, %{wake: true})

    {:ok, view, _html} = live(conn, ~p"/apps/#{armed.id}/deployments")
    view |> element("#hibernate-button") |> render_click()

    assert has_element?(
             view,
             "#hibernate-modal",
             "the next request starts it again automatically"
           )
  end

  test "shows the failure when hibernating does not stop the unit", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app = TenancyFixtures.app_fixture(scope, server, %{slug: "sleeper"})

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}/deployments")

    expect(CleatDeploy.Apps.RuntimeControlMock, :run, fn _subject, _argv ->
      {:ok, "state=active\n"}
    end)

    view |> element("#hibernate-button") |> render_click()
    html = view |> element("#confirm-hibernate-button") |> render_click()

    assert html =~ "Could not hibernate: unit phx-sleeper is active"
    refute has_element?(view, "#hibernate-modal")
  end

  test "hides the hibernate button for static apps", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app = TenancyFixtures.app_fixture(scope, server, %{runtime: "static", github_repo: ""})

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}/deployments")

    refute has_element?(view, "#hibernate-button")
  end

  test "shows which apps opted into auto sleep", %{conn: conn, scope: scope, server: server} do
    sleeper =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "sleeper",
        idle_shutdown_enabled: true
      })

    always_on = TenancyFixtures.app_fixture(scope, server, %{slug: "always-on"})

    {:ok, view, _html} = live(conn, ~p"/apps")

    assert has_element?(view, "#apps-table th", "Idle")
    assert has_element?(view, "#app-#{sleeper.id}-idle", "On")
    assert has_element?(view, "#app-#{always_on.id}-idle", "Off")
  end

  test "shows whether each app is running", %{conn: conn, scope: scope, server: server} do
    running = TenancyFixtures.app_fixture(scope, server, %{slug: "runner"})
    static = TenancyFixtures.app_fixture(scope, server, %{runtime: "static", github_repo: ""})

    {:ok, view, _html} = live(conn, ~p"/apps")
    wait_for(view, fn -> has_element?(view, "#app-#{running.id}-state", "On") end)

    assert has_element?(view, "#apps-table th", "Status")
    assert has_element?(view, "#app-#{running.id}-state", "On")
    assert has_element?(view, "#app-#{static.id}-state", "Static")

    headers = table_headers(render(view))
    idle = Enum.find_index(headers, &(&1 == "Idle"))
    assert Enum.at(headers, idle + 1) == "Status"
  end

  defp table_headers(html) do
    case Regex.run(~r/<thead>(.*?)<\/thead>/s, html) do
      [_, thead] ->
        ~r/<th[^>]*>(.*?)<\/th>/s
        |> Regex.scan(thead)
        |> Enum.map(fn [_, inner] ->
          inner |> String.replace(~r/<[^>]*>/, " ") |> String.split() |> Enum.join(" ")
        end)

      _ ->
        []
    end
  end

  test "filters apps by idle opt-in", %{conn: conn, scope: scope, server: server} do
    sleeper =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "sleeper",
        idle_shutdown_enabled: true
      })

    always_on = TenancyFixtures.app_fixture(scope, server, %{slug: "always-on"})

    {:ok, view, _html} = live(conn, ~p"/apps")

    view |> element("#apps-filter-idle-on") |> render_click()

    html = render(view)
    assert html =~ sleeper.host
    refute html =~ always_on.host
    assert_patch(view, ~p"/apps?idle=on")

    view |> element("#apps-filter-idle-off") |> render_click()

    html = render(view)
    assert html =~ always_on.host
    refute html =~ sleeper.host
    assert_patch(view, ~p"/apps?idle=off")

    view |> element("#apps-filter-idle-all") |> render_click()

    assert_patch(view, ~p"/apps")

    html = render(view)
    assert html =~ sleeper.host
    assert html =~ always_on.host
  end

  test "filters apps by status", %{conn: conn, scope: scope, server: server} do
    running = TenancyFixtures.app_fixture(scope, server, %{slug: "runner"})
    static = TenancyFixtures.app_fixture(scope, server, %{runtime: "static", github_repo: ""})

    {:ok, view, _html} = live(conn, ~p"/apps")
    wait_for(view, fn -> has_element?(view, "#app-#{running.id}-state", "On") end)

    # The memory stub reports every probed unit as active, so nothing is off.
    view |> element("#apps-filter-state-off") |> render_click()

    html = render(view)
    refute html =~ running.host
    refute html =~ static.host
    assert html =~ "No applications match this filter."
    assert_patch(view, ~p"/apps?state=off")

    view |> element("#apps-filter-state-on") |> render_click()

    html = render(view)
    assert html =~ running.host
    assert html =~ static.host
    assert_patch(view, ~p"/apps?state=on")
  end

  test "applies the new filters from the URL", %{conn: conn, scope: scope, server: server} do
    sleeper =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "sleeper",
        idle_shutdown_enabled: true
      })

    always_on = TenancyFixtures.app_fixture(scope, server, %{slug: "always-on"})

    {:ok, view, _html} = live(conn, ~p"/apps?idle=on")

    html = render(view)
    assert html =~ sleeper.host
    refute html =~ always_on.host
  end

  test "keeps the other filters when one changes", %{conn: conn, scope: scope, server: server} do
    go_sleeper =
      TenancyFixtures.app_fixture(scope, server, %{
        runtime: "golang",
        idle_shutdown_enabled: true
      })

    phx_sleeper =
      TenancyFixtures.app_fixture(scope, server, %{
        runtime: "phoenix",
        idle_shutdown_enabled: true
      })

    {:ok, view, _html} = live(conn, ~p"/apps?runtime=golang")

    view |> element("#apps-filter-idle-on") |> render_click()

    assert_patch(view, ~p"/apps?idle=on&runtime=golang")

    html = render(view)
    assert html =~ go_sleeper.host
    refute html =~ phx_sleeper.host
  end

  test "hibernates an app from the list after confirming", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app = TenancyFixtures.app_fixture(scope, server, %{slug: "sleeper"})

    {:ok, view, _html} = live(conn, ~p"/apps")
    wait_for(view, fn -> has_element?(view, "#app-#{app.id}-state", "On") end)

    assert has_element?(view, "#app-#{app.id}-hibernate")
    refute has_element?(view, "#apps-hibernate-modal")

    view |> element("#app-#{app.id}-hibernate") |> render_click()

    assert has_element?(view, "#apps-hibernate-modal")
    assert has_element?(view, "#apps-hibernate-title", "Hibernate")
    refute has_element?(view, "#app-#{app.id}-wake")

    html = view |> element("#apps-keep-hibernate-button") |> render_click()
    refute has_element?(view, "#apps-hibernate-modal")
    refute html =~ "hibernated"

    expect(CleatDeploy.Apps.RuntimeControlMock, :run, fn _subject, ["bash", "-c", script] ->
      assert script =~ "sudo systemctl stop"
      {:ok, "state=inactive\n"}
    end)

    view |> element("#app-#{app.id}-hibernate") |> render_click()
    html = view |> element("#apps-confirm-hibernate-button") |> render_click()

    assert html =~ "hibernated"
    refute has_element?(view, "#apps-hibernate-modal")
  end

  test "wakes a hibernated app from the list", %{conn: conn, scope: scope, server: server} do
    previous = Application.get_env(:cleat_deploy, :runtime_memory)
    Application.put_env(:cleat_deploy, :runtime_memory, CleatDeploy.Apps.RuntimeMemoryStoppedStub)

    on_exit(fn ->
      if previous, do: Application.put_env(:cleat_deploy, :runtime_memory, previous)
    end)

    app =
      TenancyFixtures.app_fixture(scope, server, %{slug: "sleeper", systemd_unit: "phx-sleeper"})

    {:ok, view, _html} = live(conn, ~p"/apps")
    wait_for(view, fn -> has_element?(view, "#app-#{app.id}-state", "Off") end)

    assert has_element?(view, "#app-#{app.id}-state", "Off")
    refute has_element?(view, "#app-#{app.id}-hibernate")

    expect(CleatDeploy.Apps.RuntimeControlMock, :run, fn _subject, ["bash", "-c", script] ->
      assert script =~ "sudo systemctl start"
      {:ok, "state=active\n"}
    end)

    html = view |> element("#app-#{app.id}-wake") |> render_click()
    assert html =~ "is starting"
  end

  test "hides the power button for static apps", %{conn: conn, scope: scope, server: server} do
    static = TenancyFixtures.app_fixture(scope, server, %{runtime: "static", github_repo: ""})

    {:ok, view, _html} = live(conn, ~p"/apps")

    refute has_element?(view, "#app-#{static.id}-hibernate")
    refute has_element?(view, "#app-#{static.id}-wake")
  end

  test "sorts apps by idle opt-in", %{conn: conn, scope: scope, server: server} do
    TenancyFixtures.app_fixture(scope, server, %{name: "AAA plain", slug: "aaa-plain"})

    TenancyFixtures.app_fixture(scope, server, %{
      name: "ZZZ sleeper",
      slug: "zzz-sleeper",
      idle_shutdown_enabled: true
    })

    {:ok, view, html} = live(conn, ~p"/apps")
    assert app_name_order(html) == ["AAA plain", "ZZZ sleeper"]

    html = view |> element("#sort-apps-idle") |> render_click()
    assert app_name_order(html) == ["AAA plain", "ZZZ sleeper"]

    html = view |> element("#sort-apps-idle") |> render_click()
    assert app_name_order(html) == ["ZZZ sleeper", "AAA plain"]
  end

  test "sorts apps by status", %{conn: conn, scope: scope, server: server} do
    previous = Application.get_env(:cleat_deploy, :runtime_memory)
    Application.put_env(:cleat_deploy, :runtime_memory, CleatDeploy.Apps.RuntimeMemoryStoppedStub)

    on_exit(fn ->
      if previous, do: Application.put_env(:cleat_deploy, :runtime_memory, previous)
    end)

    running =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "AAA running",
        slug: "aaa-running",
        systemd_unit: "phx-aaa-running"
      })

    TenancyFixtures.app_fixture(scope, server, %{
      name: "ZZZ sleeping",
      slug: "zzz-sleeping",
      systemd_unit: "phx-sleeper"
    })

    {:ok, view, _html} = live(conn, ~p"/apps")
    wait_for(view, fn -> has_element?(view, "#app-#{running.id}-state", "On") end)

    html = view |> element("#sort-apps-state") |> render_click()
    assert app_name_order(html) == ["AAA running", "ZZZ sleeping"]

    html = view |> element("#sort-apps-state") |> render_click()
    assert app_name_order(html) == ["ZZZ sleeping", "AAA running"]
  end

  # The systemd probe and the journal read run in background tasks so the page
  # never blocks on SSH; wait (bounded, without sleeps) for their result before
  # asserting on it. Each `:sys.get_state` is a barrier that drains the queue.
  defp wait_for(view, matcher, attempts \\ 200) do
    Enum.reduce_while(1..attempts, :timeout, fn _, _ ->
      _ = :sys.get_state(view.pid)
      if matcher.(), do: {:halt, :ok}, else: {:cont, :timeout}
    end)
  end

  test "shows the managed addons, their status and rotates credentials", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app = TenancyFixtures.app_fixture(scope, server, %{slug: "chatwoot"})

    {:ok, app} =
      CleatDeploy.Apps.record_deploy_manifest(app, %{
        units: ["worker"],
        addons: ["postgres:pgvector", "redis"]
      })

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}?tab=environment")

    wait_for(view, fn -> has_element?(view, "#addon-postgres-pgvector", "Running") end)

    assert has_element?(view, "#app-addons")
    assert has_element?(view, "#addon-postgres-pgvector", "Running · cleat_chatwoot")
    assert has_element?(view, "#addon-redis", "Running · cleat_chatwoot")

    # The probe can be re-run without reloading the page.
    html = view |> element("#refresh-addons") |> render_click()

    assert html =~ "Checking the server…"

    wait_for(view, fn -> has_element?(view, "#addon-redis", "Running · cleat_chatwoot") end)

    # Rotating asks for confirmation first.
    view |> element("#rotate-postgres-pgvector") |> render_click()

    assert has_element?(view, "#rotate-addon-modal")
    assert has_element?(view, "#rotate-addon-title", "Rotate Postgres credentials?")

    view |> element("#keep-addon-credentials-button") |> render_click()

    refute has_element?(view, "#rotate-addon-modal")
    assert CleatDeploy.Apps.env_map(app)["DATABASE_URL"] == nil

    before = CleatDeploy.Apps.env_map(app)["DATABASE_URL"]

    view |> element("#rotate-postgres-pgvector") |> render_click()
    html = view |> element("#confirm-rotate-addon-button") |> render_click()

    assert html =~ "New credentials stored"
    refute has_element?(view, "#rotate-addon-modal")

    refute CleatDeploy.Apps.env_map(app)["DATABASE_URL"] == before
    assert CleatDeploy.Apps.env_map(app)["DATABASE_URL"] =~ "postgres://cleat_chatwoot:"
  end

  test "hides the addons card for apps without addons", %{
    conn: conn,
    scope: scope,
    server: server
  } do
    app = TenancyFixtures.app_fixture(scope, server, %{slug: "plain"})

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}?tab=environment")

    refute has_element?(view, "#app-addons")
  end

  defp app_name_order(html) do
    html
    |> then(&Regex.scan(~r/href="\/apps\/\d+\/deployments"[^>]*>\s*([^<]+)\s*</, &1))
    |> Enum.map(fn [_, name] -> String.trim(name) end)
    |> Enum.uniq()
  end
end
