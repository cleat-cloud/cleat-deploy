defmodule CleatDeploy.Deploy.RuntimeTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Deploy.Runtime
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    tmp = System.tmp_dir!()
    repo_path = Path.join(tmp, "runtime_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(repo_path)
    on_exit(fn -> File.rm_rf(repo_path) end)
    %{scope: scope, server: server, repo_path: repo_path}
  end

  test "detects golang from go.mod", %{scope: scope, server: server, repo_path: repo_path} do
    File.write!(Path.join(repo_path, "go.mod"), "module github.com/puppe1990/atelie\n")

    {:ok, app, _} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Atelie",
        slug: "atelie",
        github_repo: "puppe1990/atelie",
        host: "atelie.gestaobem.com",
        server_id: server.id
      })

    assert Runtime.kind(repo_path, app) == :golang
  end

  test "detects phoenix from mix.exs", %{scope: scope, server: server, repo_path: repo_path} do
    File.write!(Path.join(repo_path, "mix.exs"), "defmodule Demo.MixProject do\nend\n")

    {:ok, app, _} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Vexo",
        slug: "vexo",
        github_repo: "puppe1990/vexo",
        host: "vexo.gestaobem.com",
        server_id: server.id
      })

    assert Runtime.kind(repo_path, app) == :phoenix
  end

  test "app.runtime golang wins over mix.exs", %{
    scope: scope,
    server: server,
    repo_path: repo_path
  } do
    File.write!(Path.join(repo_path, "mix.exs"), "defmodule Demo.MixProject do\nend\n")

    {:ok, app, _} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Atelie",
        slug: "atelie",
        github_repo: "puppe1990/atelie-forced",
        host: "atelie.gestaobem.com",
        runtime: "golang",
        server_id: server.id
      })

    assert Runtime.kind(repo_path, app) == :golang
  end

  test "app.runtime node is detected as node", %{
    scope: scope,
    server: server,
    repo_path: repo_path
  } do
    File.write!(Path.join(repo_path, "package.json"), ~s({"dependencies": {"next": "15.0.0"}}))

    {:ok, app, _} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Cleat Web",
        slug: "cleat-web",
        github_repo: "puppe1990/cleat-web",
        host: "web.gestaobem.com",
        runtime: "node",
        server_id: server.id
      })

    assert Runtime.kind(repo_path, app) == :node
  end

  test "detects rails from Gemfile and config/application.rb", %{
    scope: scope,
    server: server,
    repo_path: repo_path
  } do
    File.write!(Path.join(repo_path, "Gemfile"), ~s(gem "rails", "~> 7.1"\n))
    File.mkdir_p!(Path.join(repo_path, "config"))
    File.write!(Path.join(repo_path, "config/application.rb"), "module Loja\nend\n")

    {:ok, app, _} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Loja",
        slug: "loja",
        github_repo: "puppe1990/loja",
        host: "loja.gestaobem.com",
        server_id: server.id
      })

    assert Runtime.kind(repo_path, app) == :rails
  end

  test "app.runtime rails is detected as rails", %{
    scope: scope,
    server: server,
    repo_path: repo_path
  } do
    {:ok, app, _} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Loja",
        slug: "loja-forced",
        github_repo: "puppe1990/loja-forced",
        host: "loja-forced.gestaobem.com",
        runtime: "rails",
        server_id: server.id
      })

    assert Runtime.kind(repo_path, app) == :rails
  end

  test "detects rust from Cargo.toml", %{scope: scope, server: server, repo_path: repo_path} do
    File.write!(
      Path.join(repo_path, "Cargo.toml"),
      """
      [package]
      name = "hello_loco"
      version = "0.1.0"
      edition = "2021"

      [dependencies]
      loco-rs = { version = "0.16" }
      """
    )

    {:ok, app, _} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Hello Loco",
        slug: "hello-loco",
        github_repo: "puppe1990/hello-loco",
        host: "hello-loco.gestaobem.com",
        server_id: server.id
      })

    assert Runtime.kind(repo_path, app) == :rust
  end

  test "app.runtime rust is detected as rust", %{
    scope: scope,
    server: server,
    repo_path: repo_path
  } do
    {:ok, app, _} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Hello Loco",
        slug: "hello-loco-forced",
        github_repo: "puppe1990/hello-loco-forced",
        host: "hello-loco-forced.gestaobem.com",
        runtime: "rust",
        server_id: server.id
      })

    assert Runtime.kind(repo_path, app) == :rust
  end

  test "detects gleam from gleam.toml", %{scope: scope, server: server, repo_path: repo_path} do
    File.write!(
      Path.join(repo_path, "gleam.toml"),
      """
      name = "minha_app"
      version = "0.1.0"
      target = "erlang"
      """
    )

    {:ok, app, _} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Minha App",
        slug: "minha-app",
        github_repo: "puppe1990/minha-app",
        host: "minha-app.gestaobem.com",
        server_id: server.id
      })

    assert Runtime.kind(repo_path, app) == :gleam
  end

  test "app.runtime gleam is detected as gleam", %{
    scope: scope,
    server: server,
    repo_path: repo_path
  } do
    {:ok, app, _} =
      CleatDeploy.Apps.create_app(scope, %{
        name: "Minha App",
        slug: "minha-app-forced",
        github_repo: "puppe1990/minha-app-forced",
        host: "minha-app-forced.gestaobem.com",
        runtime: "gleam",
        server_id: server.id
      })

    assert Runtime.kind(repo_path, app) == :gleam
  end
end
