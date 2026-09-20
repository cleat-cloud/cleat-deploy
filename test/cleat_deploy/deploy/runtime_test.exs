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
end
