defmodule CleatDeploy.Deploy.AppManifestTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Deploy.AppManifest
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    {:ok, app, _webhook_status} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Catálogo",
        slug: "catalogo",
        github_repo: "gestao-bem/catalog_platform",
        host: "loja.gestaobem.com",
        port: 4000,
        server_id: server.id
      })

    tmp = System.tmp_dir!()
    repo_path = Path.join(tmp, "catalog_manifest_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(repo_path, ".cleat_deploy"))

    File.write!(
      Path.join(repo_path, ".cleat_deploy/deploy.json"),
      ~s({
        "solo_server": true,
        "caddyfile": "deploy/Caddyfile",
        "caddy_mode": "replace",
        "memory_max_mb": 1024
      })
    )

    on_exit(fn -> File.rm_rf(repo_path) end)

    %{app: app, server: server, repo_path: repo_path}
  end

  test "resolve reads deploy.json from repo", %{app: app, repo_path: repo_path} do
    manifest = AppManifest.resolve(repo_path, app)

    assert manifest.solo_server
    assert manifest.caddy_mode == "replace"
    assert manifest.caddyfile == "deploy/Caddyfile"
    assert manifest.memory_max_mb == 1024
    assert manifest.domain_checklist?
  end

  test "resolve reads build_dir from deploy.json", %{app: app, repo_path: repo_path} do
    File.write!(
      Path.join(repo_path, ".cleat_deploy/deploy.json"),
      ~s({"build_dir": "assistente", "release_name": "assistente"})
    )

    manifest = AppManifest.resolve(repo_path, app)

    assert manifest.build_dir == "assistente"
    assert manifest.release_name == "assistente"
  end

  test "resolve reads node runtime and commands from deploy.json", %{
    app: app,
    repo_path: repo_path
  } do
    File.write!(
      Path.join(repo_path, ".cleat_deploy/deploy.json"),
      ~s({"runtime": "node", "build_command": "npm run build:prod",
          "start_command": "npm start", "node_version": "20"})
    )

    manifest = AppManifest.resolve(repo_path, app)

    assert manifest.runtime == "node"
    assert manifest.build_command == "npm run build:prod"
    assert manifest.start_command == "npm start"
    assert manifest.node_version == "20"
  end

  test "validate_for_server rejects solo app on shared server", %{
    app: app,
    server: server,
    repo_path: repo_path
  } do
    manifest = AppManifest.resolve(repo_path, app)

    assert {:error, _} = AppManifest.validate_for_server(manifest, server, [app], app)
  end

  test "validate_for_server accepts solo app on dedicated server", %{
    app: app,
    server: server,
    repo_path: repo_path
  } do
    server = %{server | deploy_mode: "dedicated"}
    manifest = AppManifest.resolve(repo_path, app)

    assert :ok = AppManifest.validate_for_server(manifest, server, [app], app)
  end

  test "resolve reads Mix app atom as release_name when slug differs" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    {:ok, app, _} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Decor",
        slug: "decor",
        github_repo: "gestao-bem/gestao-bem-decor",
        host: "decor.gestaobem.com",
        port: 4005,
        server_id: server.id
      })

    tmp = System.tmp_dir!()
    repo_path = Path.join(tmp, "decor_manifest_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(repo_path)

    File.write!(
      Path.join(repo_path, "mix.exs"),
      """
      defmodule FestaPlatform.MixProject do
        use Mix.Project
        def project, do: [app: :festa_platform, version: "0.1.0"]
      end
      """
    )

    on_exit(fn -> File.rm_rf(repo_path) end)

    manifest = AppManifest.resolve(repo_path, app)
    assert manifest.release_name == "festa_platform"
  end

  test "infers node for a TanStack Start repo without deploy.json" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server, %{runtime: "phoenix"})

    repo_path =
      tmp_repo(%{
        "package.json" =>
          ~s({"dependencies": {"@tanstack/react-start": "latest", "react": "^19"}})
      })

    assert AppManifest.resolve(repo_path, app).runtime == "node"
  end

  test "infers static for a package.json without a JS framework" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server, %{runtime: "phoenix"})

    repo_path = tmp_repo(%{"package.json" => ~s({"dependencies": {"left-pad": "^1.0.0"}})})

    assert AppManifest.resolve(repo_path, app).runtime == "static"
  end

  test "deploy.json runtime wins over detection" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server, %{runtime: "phoenix"})

    repo_path =
      tmp_repo(%{
        "package.json" => ~s({"dependencies": {"@tanstack/react-start": "latest"}}),
        ".cleat_deploy/deploy.json" => ~s({"runtime": "static"})
      })

    assert AppManifest.resolve(repo_path, app).runtime == "static"
  end

  test "keeps an explicit non-phoenix runtime even without framework files" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server, %{runtime: "node"})

    repo_path = tmp_repo(%{"package.json" => ~s({"dependencies": {"left-pad": "^1.0.0"}})})

    assert AppManifest.resolve(repo_path, app).runtime == "node"
  end

  defp tmp_repo(files) do
    path = Path.join(System.tmp_dir!(), "manifest_detect_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(path)

    Enum.each(files, fn {relative, content} ->
      full = Path.join(path, relative)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
