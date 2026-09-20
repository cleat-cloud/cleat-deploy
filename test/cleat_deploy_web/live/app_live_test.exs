defmodule CleatDeployWeb.AppLiveTest do
  use CleatDeployWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CleatDeploy.{Apps, Deployments}
  alias CleatDeploy.TenancyFixtures

  setup :register_and_log_in_user

  setup %{scope: scope} do
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

    html = view |> element("#apps-page-next") |> render_click()

    assert html =~ "App 11"
    assert html =~ "App 12"
    refute html =~ "App 01"
    assert has_element?(view, "#apps-page-status", "11-12 of 12")
    assert has_element?(view, "#apps-page-next[disabled]")
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
    _ = :sys.get_state(view.pid)
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
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#app-memory-tile", "163 MB")
    assert has_element?(view, "#app-cpu-tile", "2.8%")
    assert has_element?(view, "#app-disk-tile", "510 MB")
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

    {:ok, view, html} = live(conn, ~p"/apps/#{app.id}?tab=logs")
    assert has_element?(view, "#app-detail-tab-logs")
    assert has_element?(view, "#app-runtime-logs")
    assert has_element?(view, "#refresh-app-logs")
    assert html =~ "2026-09-06T12:00:00Z"

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

    view |> element("#deployments-page-next") |> render_click()

    assert has_element?(view, "#deployments-page-status", "11-11 of 11")
    assert has_element?(view, "#deployments-#{oldest.id}")
    refute has_element?(view, "#deployments-#{newest.id}")
    refute has_element?(view, "#deployments-page-prev[disabled]")
    assert has_element?(view, "#deployments-page-next[disabled]")

    view |> element("#deployments-page-prev") |> render_click()

    assert has_element?(view, "#deployments-page-status", "1-10 of 11")
    assert has_element?(view, "#deployments-#{newest.id}")
    refute has_element?(view, "#deployments-#{oldest.id}")
  end

  defp app_name_order(html) do
    html
    |> then(&Regex.scan(~r/href="\/apps\/\d+\/deployments"[^>]*>\s*([^<]+)\s*</, &1))
    |> Enum.map(fn [_, name] -> String.trim(name) end)
    |> Enum.uniq()
  end
end
