defmodule CleatDeploy.Servers.InsightsTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Deployments
  alias CleatDeploy.Servers.Insights
  alias CleatDeploy.Settings
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope, %{name: "gestaobem-cx33"})
    %{scope: scope, server: server}
  end

  test "counts apps by runtime for the tenant", %{scope: scope, server: server} do
    TenancyFixtures.app_fixture(scope, server, %{runtime: "phoenix", slug: "a1", name: "A1"})
    TenancyFixtures.app_fixture(scope, server, %{runtime: "phoenix", slug: "a2", name: "A2"})
    TenancyFixtures.app_fixture(scope, server, %{runtime: "golang", slug: "g1", name: "G1"})

    snapshot = Insights.snapshot(scope)
    assert snapshot.runtimes.elixir == 2
    assert snapshot.runtimes.go == 1
    assert snapshot.server.id == server.id
  end

  test "buckets deployments by day and status", %{scope: scope, server: server} do
    app = TenancyFixtures.app_fixture(scope, server)

    {:ok, queued} = Deployments.create_deployment(app, %{git_sha: "ok"})
    {:ok, running} = Deployments.mark_running(queued)
    {:ok, _} = Deployments.mark_success(running, "ok")

    {:ok, failed_q} = Deployments.create_deployment(app, %{git_sha: "bad"})
    {:ok, _} = Deployments.mark_failed(failed_q, "boom")

    snapshot = Insights.snapshot(scope)
    today = List.last(snapshot.deploys)

    assert today.success >= 1
    assert today.failed >= 1
    assert length(snapshot.deploys) == 14
  end

  test "does not include other tenant apps", %{scope: scope, server: server} do
    TenancyFixtures.app_fixture(scope, server, %{runtime: "golang", slug: "mine", name: "Mine"})
    other = TenancyFixtures.scope_fixture()
    other_server = TenancyFixtures.server_fixture(other)

    TenancyFixtures.app_fixture(other, other_server, %{
      runtime: "golang",
      slug: "theirs",
      name: "Theirs"
    })

    snapshot = Insights.snapshot(scope)
    assert snapshot.runtimes.go == 1
    assert snapshot.runtimes.elixir == 0
  end

  test "uses the server chosen in the settings", %{scope: scope} do
    chosen =
      TenancyFixtures.server_fixture(scope, %{name: "escolhido", instance_status: "stopped"})

    assert {:ok, _} = Settings.put_active_server(scope, chosen.id)

    assert Insights.snapshot(scope).server.id == chosen.id
  end

  test "counts runtimes and deploys for the active server only", %{
    scope: scope,
    server: server
  } do
    other =
      TenancyFixtures.server_fixture(scope, %{name: "other-box", instance_status: "stopped"})

    TenancyFixtures.app_fixture(scope, server, %{
      runtime: "phoenix",
      slug: "on-primary",
      name: "P"
    })

    TenancyFixtures.app_fixture(scope, server, %{runtime: "golang", slug: "go-primary", name: "G"})

    other_app =
      TenancyFixtures.app_fixture(scope, other, %{runtime: "node", slug: "on-other", name: "N"})

    {:ok, queued} = Deployments.create_deployment(other_app, %{git_sha: "other"})
    {:ok, running} = Deployments.mark_running(queued)
    {:ok, _} = Deployments.mark_success(running, "ok")

    assert {:ok, _} = Settings.put_active_server(scope, server.id)

    snapshot = Insights.snapshot(scope)
    assert snapshot.runtimes.elixir == 1
    assert snapshot.runtimes.go == 1
    assert snapshot.runtimes.node == 0
    assert List.last(snapshot.deploys).success == 0

    assert {:ok, _} = Settings.put_active_server(scope, other.id)

    switched = Insights.snapshot(scope)
    assert switched.runtimes.elixir == 0
    assert switched.runtimes.node == 1
    assert List.last(switched.deploys).success >= 1
  end

  test "ignores a choice that does not belong to the tenant", %{scope: scope, server: server} do
    other = TenancyFixtures.scope_fixture()
    foreign = TenancyFixtures.server_fixture(other)

    assert {:ok, _} = Settings.put_active_server(scope, foreign.id)

    assert Insights.snapshot(scope).server.id == server.id
  end
end
