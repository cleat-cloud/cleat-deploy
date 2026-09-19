defmodule CleatDeploy.Apps.HostTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps
  alias CleatDeploy.TenancyFixtures

  defp attrs(server, overrides) do
    Map.merge(
      %{
        name: "App #{System.unique_integer([:positive])}",
        slug: "app-#{System.unique_integer([:positive])}",
        github_repo: "owner/repo-#{System.unique_integer([:positive])}",
        host: "host-#{System.unique_integer([:positive])}.example.com",
        server_id: server.id
      },
      overrides
    )
  end

  test "two apps on the same server cannot share a host" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    {:ok, _app, _} = Apps.create_app(scope, attrs(server, %{host: "shared.example.com"}))

    assert {:error, changeset} =
             Apps.create_app(scope, attrs(server, %{host: "shared.example.com"}))

    assert %{host: ["has already been taken"]} = errors_on(changeset)
  end

  test "the same host is allowed on a different server" do
    scope = TenancyFixtures.scope_fixture()
    server_a = TenancyFixtures.server_fixture(scope)
    server_b = TenancyFixtures.server_fixture(scope)

    assert {:ok, _app, _} = Apps.create_app(scope, attrs(server_a, %{host: "same.example.com"}))
    assert {:ok, _app, _} = Apps.create_app(scope, attrs(server_b, %{host: "same.example.com"}))
  end

  test "hosts are normalized to lowercase, so case variants collide" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    assert {:ok, app, _} =
             Apps.create_app(scope, attrs(server, %{host: "MiXeD.Example.com."}))

    assert app.host == "mixed.example.com"

    assert {:error, changeset} =
             Apps.create_app(scope, attrs(server, %{host: "mixed.example.com"}))

    assert %{host: ["has already been taken"]} = errors_on(changeset)
  end
end
