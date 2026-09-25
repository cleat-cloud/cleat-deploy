defmodule CleatDeploy.AppsTest do
  use CleatDeploy.DataCase

  alias CleatDeploy.Apps
  alias CleatDeploy.Apps.App
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    %{scope: scope, server: server}
  end

  describe "webhook_secret" do
    test "is stored encrypted and loads as plaintext", %{scope: scope, server: server} do
      app = TenancyFixtures.app_fixture(scope, server)
      plaintext = app.webhook_secret

      assert is_binary(plaintext) and plaintext != ""

      %{rows: [[raw]]} =
        CleatDeploy.Repo.query!("SELECT webhook_secret FROM apps WHERE id = ?", [app.id])

      refute raw == plaintext
      assert Apps.get_app!(scope, app.id).webhook_secret == plaintext
    end
  end

  describe "page_apps/2" do
    test "returns one page and the matching total", %{scope: scope, server: server} do
      for n <- 1..12 do
        TenancyFixtures.app_fixture(scope, server, %{
          name: "App #{String.pad_leading(Integer.to_string(n), 2, "0")}",
          slug: "app-#{n}",
          host: "app-#{n}.example.com"
        })
      end

      page = Apps.page_apps(scope, page: 1, page_size: 10)

      assert page.total == 12
      assert page.page == 1
      assert page.page_size == 10
      assert length(page.entries) == 10
      assert hd(page.entries).name == "App 01"
      assert hd(page.entries).server.id == server.id

      page2 = Apps.page_apps(scope, page: 2, page_size: 10)
      assert Enum.map(page2.entries, & &1.name) == ["App 11", "App 12"]
    end

    test "filters by query, runtime and idle in SQL", %{scope: scope, server: server} do
      TenancyFixtures.app_fixture(scope, server, %{
        name: "Vexo",
        slug: "vexo",
        runtime: "golang",
        idle_shutdown_enabled: true
      })

      TenancyFixtures.app_fixture(scope, server, %{
        name: "Atelie",
        slug: "atelie",
        runtime: "phoenix"
      })

      assert %{total: 1, entries: [%{slug: "vexo"}]} =
               Apps.page_apps(scope, query: "vexo")

      assert %{total: 1, entries: [%{slug: "vexo"}]} =
               Apps.page_apps(scope, runtime: :golang)

      assert %{total: 1, entries: [%{slug: "vexo"}]} =
               Apps.page_apps(scope, idle: :on)
    end
  end

  describe "change_app/2" do
    test "does not set deploy defaults when slug is missing" do
      changeset = Apps.change_app(%CleatDeploy.Apps.App{})

      assert Ecto.Changeset.get_field(changeset, :systemd_unit) == nil
      assert Ecto.Changeset.get_field(changeset, :release_path) == nil
    end

    test "sets deploy defaults when slug is provided" do
      changeset = Apps.change_app(%CleatDeploy.Apps.App{}, %{slug: "my-app"})

      assert Ecto.Changeset.get_field(changeset, :systemd_unit) == "phx-my-app"
      assert Ecto.Changeset.get_field(changeset, :release_path) == "/opt/my_app"
    end

    test "vexo uses vexo systemd unit and /opt/vexo" do
      changeset = Apps.change_app(%CleatDeploy.Apps.App{}, %{slug: "vexo"})

      assert Ecto.Changeset.get_field(changeset, :systemd_unit) == "vexo"
      assert Ecto.Changeset.get_field(changeset, :release_path) == "/opt/vexo"
    end

    test "golang runtime uses slug as unit and /opt/slug" do
      changeset =
        Apps.change_app(%CleatDeploy.Apps.App{}, %{slug: "atelie", runtime: "golang"})

      assert Ecto.Changeset.get_field(changeset, :runtime) == "golang"
      assert Ecto.Changeset.get_field(changeset, :systemd_unit) == "atelie"
      assert Ecto.Changeset.get_field(changeset, :release_path) == "/opt/atelie"
    end

    test "rust runtime uses rust-<slug> unit and /opt/slug" do
      changeset =
        Apps.change_app(%CleatDeploy.Apps.App{}, %{slug: "hello-loco", runtime: "rust"})

      assert Ecto.Changeset.get_field(changeset, :runtime) == "rust"
      assert Ecto.Changeset.get_field(changeset, :systemd_unit) == "rust-hello-loco"
      assert Ecto.Changeset.get_field(changeset, :release_path) == "/opt/hello-loco"
    end
  end

  describe "main_language/1" do
    test "maps phoenix runtime to Elixir and golang to Go" do
      assert App.main_language(%App{runtime: "phoenix"}) == "Elixir"
      assert App.main_language(%App{runtime: "golang"}) == "Go"
      assert App.main_language(%App{runtime: "rust"}) == "Rust"
      assert App.main_language(%App{runtime: nil}) == "Elixir"
    end
  end

  describe "data_dir/1" do
    test "keeps runtime data outside the release dir" do
      assert App.data_dir(%App{runtime: "node", slug: "leitor", release_path: "/opt/leitor"}) ==
               "/opt/leitor/data"

      assert App.data_dir(%App{runtime: "golang", slug: "trama", release_path: "/opt/trama"}) ==
               "/opt/trama/data"

      assert App.data_dir(%App{runtime: "phoenix", slug: "tts", release_path: "/opt/phoenix_tts"}) ==
               "/var/lib/phoenix_tts"
    end

    test "static apps have no data dir" do
      assert App.data_dir(%App{runtime: "static", slug: "site", release_path: "/var/www/site"}) ==
               nil
    end
  end

  describe "count_apps/1" do
    test "counts tenant apps without loading them", %{scope: scope, server: server} do
      assert Apps.count_apps(scope) == 0

      {:ok, _app, _} =
        Apps.create_app(scope, %{
          name: "Trip Planner",
          slug: "trip-planner",
          github_repo: "puppe1990/trip-planner-ia-phx",
          host: "trip.gestaobem.com",
          server_id: server.id
        })

      assert Apps.count_apps(scope) == 1
      assert Apps.count_apps(TenancyFixtures.scope_fixture()) == 0
    end
  end

  describe "create_app/2" do
    test "persists app linked to server", %{scope: scope, server: server} do
      attrs = %{
        name: "Trip Planner",
        slug: "trip-planner",
        github_repo: "puppe1990/trip-planner-ia-phx",
        host: "trip.gestaobem.com",
        server_id: server.id
      }

      assert {:ok, app, _webhook_status} = Apps.create_app(scope, attrs)
      assert app.tenant_id == scope.tenant.id
      assert app.systemd_unit == "trip_planner_ia"
      assert app.release_path == "/opt/trip_planner_ia"
    end

    test "requires github_repo, host, and server_id", %{scope: scope, server: server} do
      assert {:error, changeset} =
               Apps.create_app(scope, %{name: "X", slug: "x", server_id: server.id})

      assert "can't be blank" in errors_on(changeset).github_repo
      assert "can't be blank" in errors_on(changeset).host
    end

    test "assigns a free port when the requested one is taken", %{scope: scope, server: server} do
      first = TenancyFixtures.app_fixture(scope, server, %{port: 4000})
      assert first.port == 4000

      {:ok, second, _} =
        Apps.create_app(scope, %{
          name: "Second",
          slug: "second",
          github_repo: "owner/second",
          host: "second.example.com",
          server_id: server.id,
          port: 4000
        })

      assert second.port == 4001
    end

    test "keeps an explicit port that is free", %{scope: scope, server: server} do
      {:ok, app, _} =
        Apps.create_app(scope, %{
          name: "Third",
          slug: "third",
          github_repo: "owner/third",
          host: "third.example.com",
          server_id: server.id,
          port: 4050
        })

      assert app.port == 4050
    end
  end

  describe "allocate_port/2" do
    test "returns the preferred port when free", %{server: server} do
      assert Apps.allocate_port(server.id, 4025) == 4025
    end

    test "skips ports already used on the server", %{scope: scope, server: server} do
      TenancyFixtures.app_fixture(scope, server, %{port: 4000})

      assert Apps.allocate_port(server.id, 4000) == 4001
      assert Apps.allocate_port(server.id) == 4001
    end

    test "is scoped per server", %{scope: scope, server: server} do
      other_server =
        TenancyFixtures.server_fixture(scope, %{name: "other-#{System.unique_integer()}"})

      TenancyFixtures.app_fixture(scope, server, %{port: 4000})

      assert Apps.allocate_port(other_server.id) == 4000
    end

    test "never hands out the panel's own port", %{server: server} do
      previous = System.get_env("PORT")
      System.put_env("PORT", "4010")
      on_exit(fn -> restore_env("PORT", previous) end)

      assert Apps.allocate_port(server.id, 4010) == 4000
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  describe "update_app_settings/3" do
    test "updates the port", %{scope: scope, server: server} do
      app = TenancyFixtures.app_fixture(scope, server, %{port: 4000})

      assert {:ok, updated} = Apps.update_app_settings(scope, app, %{"port" => 4030})
      assert updated.port == 4030
    end

    test "rejects a port already used on the same server", %{scope: scope, server: server} do
      TenancyFixtures.app_fixture(scope, server, %{port: 4000})
      other = TenancyFixtures.app_fixture(scope, server, %{port: 4001})

      assert {:error, changeset} = Apps.update_app_settings(scope, other, %{"port" => 4000})
      assert "has already been taken" in errors_on(changeset).port
    end

    test "updates the host", %{scope: scope, server: server} do
      app = TenancyFixtures.app_fixture(scope, server)

      assert {:ok, updated} =
               Apps.update_app_settings(scope, app, %{"host" => "moved.example.com"})

      assert updated.host == "moved.example.com"
    end

    test "updates the repo", %{scope: scope, server: server} do
      app = TenancyFixtures.app_fixture(scope, server)

      assert {:ok, updated} =
               Apps.update_app_settings(scope, app, %{"github_repo" => "owner/new-repo"})

      assert updated.github_repo == "owner/new-repo"
    end

    test "rejects a malformed repo", %{scope: scope, server: server} do
      app = TenancyFixtures.app_fixture(scope, server)

      assert {:error, changeset} =
               Apps.update_app_settings(scope, app, %{"github_repo" => "not-a-repo"})

      assert "must be owner/repo" in errors_on(changeset).github_repo
    end

    test "updates the runtime and re-derives the systemd unit and data dir", %{
      scope: scope,
      server: server
    } do
      app = TenancyFixtures.app_fixture(scope, server, %{runtime: "phoenix"})

      assert {:ok, updated} = Apps.update_app_settings(scope, app, %{"runtime" => "node"})
      assert updated.runtime == "node"
      assert updated.systemd_unit == "node-#{updated.slug}"
      assert App.data_dir(updated) == "#{updated.release_path}/data"
    end

    test "updates indexable", %{scope: scope, server: server} do
      app = TenancyFixtures.app_fixture(scope, server, %{runtime: "static"})
      refute app.indexable

      assert {:ok, updated} = Apps.update_app_settings(scope, app, %{"indexable" => true})
      assert updated.indexable
    end

    test "rejects an unknown runtime", %{scope: scope, server: server} do
      app = TenancyFixtures.app_fixture(scope, server)

      assert {:error, changeset} =
               Apps.update_app_settings(scope, app, %{"runtime" => "elixir"})

      assert "is invalid" in errors_on(changeset).runtime
    end
  end

  describe "runtime_packages_text" do
    test "parses newline-separated apt packages from form text" do
      changeset =
        App.changeset(%App{}, %{
          "runtime_packages_text" => "zip\nffmpeg imagemagick"
        })

      assert Ecto.Changeset.get_field(changeset, :runtime_apt_packages) == [
               "zip",
               "ffmpeg",
               "imagemagick"
             ]
    end
  end

  describe "env var display helpers" do
    test "sensitive_env_key?/1 detects secrets and tokens" do
      assert Apps.sensitive_env_key?("SECRET_KEY_BASE")
      assert Apps.sensitive_env_key?("TURSO_AUTH_TOKEN")
      assert Apps.sensitive_env_key?("ASSEMBLYAI_API_KEY")
      refute Apps.sensitive_env_key?("PHX_HOST")
      refute Apps.sensitive_env_key?("PORT")
    end

    test "display_env_value/3 masks sensitive values unless revealed" do
      assert Apps.display_env_value("SECRET_KEY_BASE", "super-secret", false) =~ "•"
      assert Apps.display_env_value("SECRET_KEY_BASE", "super-secret", true) == "super-secret"
      assert Apps.display_env_value("PORT", "4003", false) == "4003"
    end

    test "list_env_vars_for_display/1 returns sorted vars", %{scope: scope, server: server} do
      {:ok, app, _webhook_status} =
        Apps.create_app(scope, %{
          name: "Trip Planner",
          slug: "trip-planner",
          github_repo: "puppe1990/trip-planner-ia-phx",
          host: "trip.gestaobem.com",
          server_id: server.id
        })

      {:ok, _} = Apps.put_env_var(app, "PORT", "4003")
      {:ok, _} = Apps.put_env_var(app, "SECRET_KEY_BASE", "super-secret")

      assert [%{key: "PORT"}, %{key: "SECRET_KEY_BASE", sensitive?: true}] =
               Apps.list_env_vars_for_display(app)
    end
  end

  describe "env_map/1" do
    test "includes PHX_HOST and stored env vars", %{scope: scope, server: server} do
      {:ok, app, _webhook_status} =
        Apps.create_app(scope, %{
          name: "Trip Planner",
          slug: "trip-planner",
          github_repo: "puppe1990/trip-planner-ia-phx",
          host: "trip.gestaobem.com",
          server_id: server.id
        })

      {:ok, _} = Apps.put_env_var(app, "SECRET_KEY_BASE", "super-secret")
      {:ok, _} = Apps.put_env_var(app, "GEMINI_API_KEY", "gemini-key")

      assert Apps.env_map(app) == %{
               "PHX_HOST" => "trip.gestaobem.com",
               "SECRET_KEY_BASE" => "super-secret",
               "GEMINI_API_KEY" => "gemini-key"
             }
    end

    test "with a branch, keeps the all-branches vars and overrides by key", %{
      scope: scope,
      server: server
    } do
      {:ok, app, _} =
        Apps.create_app(scope, %{
          name: "Purple Stock",
          slug: "purple-stock",
          github_repo: "puppe1990/purple-stock",
          host: "purplestock.gestaobem.com",
          server_id: server.id
        })

      {:ok, _} = Apps.put_env_var(app, "BASE_URL", "https://purplestock.com.br")
      {:ok, _} = Apps.put_env_var(app, "GA_ID", "G-PROD")

      {:ok, _} =
        Apps.put_env_var(app, "BASE_URL", "https://staging.purplestock.com.br", "staging")

      assert Apps.env_map(app, "main") == %{
               "PHX_HOST" => "purplestock.gestaobem.com",
               "BASE_URL" => "https://purplestock.com.br",
               "GA_ID" => "G-PROD"
             }

      assert Apps.env_map(app, "staging") == %{
               "PHX_HOST" => "purplestock.gestaobem.com",
               "BASE_URL" => "https://staging.purplestock.com.br",
               "GA_ID" => "G-PROD"
             }

      # Without a branch every scope is returned: the more specific one is the
      # decisive value (branch order, so it is deterministic).
      assert Apps.env_map(app)["BASE_URL"] == "https://staging.purplestock.com.br"
    end
  end

  describe "delete_env_var/3" do
    test "only deletes the scope it was asked for", %{scope: scope, server: server} do
      {:ok, app, _} =
        Apps.create_app(scope, app_attrs(server, %{slug: "scoped-#{System.unique_integer()}"}))

      {:ok, _} = Apps.put_env_var(app, "BASE_URL", "https://prod.example.com")
      {:ok, _} = Apps.put_env_var(app, "BASE_URL", "https://staging.example.com", "staging")

      assert :ok = Apps.delete_env_var(app, "BASE_URL", "staging")
      assert Apps.env_map(app, "staging")["BASE_URL"] == "https://prod.example.com"

      assert :ok = Apps.delete_env_var(app, "BASE_URL")
      refute Map.has_key?(Apps.env_map(app, "main"), "BASE_URL")

      assert {:error, :not_found} = Apps.delete_env_var(app, "BASE_URL")
    end
  end

  describe "instances" do
    test "the same repo can be registered once per branch", %{scope: scope, server: server} do
      repo = "puppe1990/purple-stock-#{System.unique_integer()}"

      {:ok, app, _} =
        Apps.create_app(scope, app_attrs(server, %{slug: "purplestock", github_repo: repo}))

      {:ok, staging, _} =
        Apps.create_app(
          scope,
          app_attrs(server, %{
            slug: "purplestock-staging",
            github_repo: repo,
            branch: "staging",
            host: "purplestock-staging.gestaobem.com"
          })
        )

      assert staging.branch == "staging"
      assert staging.github_repo == repo
      assert staging.webhook_secret == app.webhook_secret

      assert [%{slug: "purplestock-staging"}] = Apps.list_app_instances(scope, app)
      assert [%{slug: "purplestock"}] = Apps.list_app_instances(scope, staging)
      assert Apps.get_app_by_repo(repo).id == app.id
    end

    test "the same repo on the same branch is rejected", %{scope: scope, server: server} do
      repo = "puppe1990/purple-stock-#{System.unique_integer()}"

      {:ok, _app, _} =
        Apps.create_app(scope, app_attrs(server, %{slug: "purplestock", github_repo: repo}))

      assert {:error, changeset} =
               Apps.create_app(
                 scope,
                 app_attrs(server, %{
                   slug: "purplestock-again",
                   github_repo: repo,
                   host: "purplestock-again.gestaobem.com"
                 })
               )

      assert %{github_repo: ["has already been taken"]} = errors_on(changeset)
    end
  end

  defp app_attrs(server, overrides) do
    Map.merge(
      %{
        name: "Purple Stock",
        slug: "purplestock",
        github_repo: "puppe1990/purple-stock",
        host: "purplestock.gestaobem.com",
        server_id: server.id
      },
      overrides
    )
  end

  describe "update_app/3" do
    test "updates deploy branch for the owning tenant", %{scope: scope, server: server} do
      {:ok, app, _} =
        Apps.create_app(scope, %{
          name: "PratoAI",
          slug: "prato-ai",
          github_repo: "gestao-bem/prato-ai",
          branch: "deploy-cleat",
          host: "pratoai.gestaobem.com",
          server_id: server.id
        })

      assert {:ok, updated} = Apps.update_app(scope, app, %{branch: "main"})
      assert updated.branch == "main"
      assert Apps.get_app!(scope, app.id).branch == "main"
    end

    test "strips refs/heads/ when pasted", %{scope: scope, server: server} do
      {:ok, app, _} =
        Apps.create_app(scope, %{
          name: "Ops",
          slug: "ops-app",
          github_repo: "puppe1990/ops-app",
          host: "app.gestaobem.com",
          server_id: server.id
        })

      assert {:ok, updated} = Apps.update_app(scope, app, %{"branch" => "refs/heads/feat/ledger"})
      assert updated.branch == "feat/ledger"
    end

    test "ignores non-branch fields", %{scope: scope, server: server} do
      {:ok, app, _} =
        Apps.create_app(scope, %{
          name: "Ops",
          slug: "ops-app",
          github_repo: "puppe1990/ops-app",
          host: "app.gestaobem.com",
          server_id: server.id
        })

      assert {:ok, updated} =
               Apps.update_app(scope, app, %{branch: "develop", slug: "hacked", host: "evil.com"})

      assert updated.branch == "develop"
      assert updated.slug == "ops-app"
      assert updated.host == "app.gestaobem.com"
    end

    test "rejects a blank branch", %{scope: scope, server: server} do
      {:ok, app, _} =
        Apps.create_app(scope, %{
          name: "Ops",
          slug: "ops-app",
          github_repo: "puppe1990/ops-app",
          host: "app.gestaobem.com",
          server_id: server.id
        })

      assert {:error, changeset} = Apps.update_app(scope, app, %{branch: "   "})
      assert "can't be blank" in errors_on(changeset).branch
    end

    test "rejects another tenant", %{scope: scope, server: server} do
      {:ok, app, _} =
        Apps.create_app(scope, %{
          name: "Ops",
          slug: "ops-app",
          github_repo: "puppe1990/ops-app",
          host: "app.gestaobem.com",
          server_id: server.id
        })

      assert {:error, :unauthorized} =
               Apps.update_app(TenancyFixtures.scope_fixture(), app, %{branch: "main"})
    end
  end

  describe "delete_app/2" do
    test "removes the app and cascaded env vars", %{scope: scope, server: server} do
      {:ok, app, _} =
        Apps.create_app(scope, %{
          name: "Ops",
          slug: "ops-app",
          github_repo: "puppe1990/ops-app",
          host: "app.gestaobem.com",
          server_id: server.id
        })

      {:ok, _} = Apps.put_env_var(app, "PORT", "4002")

      assert {:ok, %App{}} = Apps.delete_app(scope, app)
      assert_raise Ecto.NoResultsError, fn -> Apps.get_app!(scope, app.id) end
    end

    test "rejects another tenant", %{scope: scope, server: server} do
      {:ok, app, _} =
        Apps.create_app(scope, %{
          name: "Ops",
          slug: "ops-app",
          github_repo: "puppe1990/ops-app",
          host: "app.gestaobem.com",
          server_id: server.id
        })

      assert {:error, :unauthorized} =
               Apps.delete_app(TenancyFixtures.scope_fixture(), app)
    end
  end

  describe "deploy manifest summary" do
    test "records the extra units and addons the deploy resolved", %{scope: scope, server: server} do
      app = TenancyFixtures.app_fixture(scope, server, %{slug: "chatwoot"})

      assert App.extra_units(app) == []
      assert App.deploy_addons(app) == []

      {:ok, app} =
        Apps.record_deploy_manifest(app, %{
          units: ["worker", "scheduler"],
          addons: ["postgres:pgvector", "redis"]
        })

      assert App.extra_units(app) == ["worker", "scheduler"]
      assert App.deploy_addons(app) == ["postgres:pgvector", "redis"]

      assert App.unit_names(app) == [
               "phx-chatwoot",
               "phx-chatwoot-worker",
               "phx-chatwoot-scheduler"
             ]

      # Reloaded from the database, not just the in-memory struct.
      reloaded = Apps.get_app!(scope, app.id)
      assert App.extra_units(reloaded) == ["worker", "scheduler"]
      assert App.unit_names(reloaded) == App.unit_names(app)
    end

    test "go apps deployed before the manifest was recorded still expose -worker", %{
      scope: scope,
      server: server
    } do
      app = TenancyFixtures.app_fixture(scope, server, %{slug: "atelie", runtime: "golang"})

      assert App.extra_units(app) == ["worker"]
      assert App.unit_names(app) == ["atelie", "atelie-worker"]
    end

    test "records whether the deploy armed wake-on-request", %{scope: scope, server: server} do
      app = TenancyFixtures.app_fixture(scope, server, %{slug: "chatwoot"})

      # Nothing is armed before the first deploy records a manifest.
      refute App.wake_armed?(app)

      {:ok, app} = Apps.record_deploy_manifest(app, %{units: ["worker"], wake: true})
      assert App.wake_armed?(app)

      # A later deploy that does not arm it overwrites the summary.
      {:ok, app} = Apps.record_deploy_manifest(app, %{units: ["worker"], wake: false})

      refute App.wake_armed?(app)
      refute App.wake_armed?(Apps.get_app!(scope, app.id))
    end
  end
end
