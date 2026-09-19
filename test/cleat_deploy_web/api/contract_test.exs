defmodule CleatDeployWeb.Api.ContractTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.TenancyFixtures
  alias CleatDeployWeb.Api.{Contract, Serializer}

  test "priv/api_contract.json matches the Contract module" do
    on_disk = "priv/api_contract.json" |> File.read!() |> Jason.decode!()
    assert on_disk == Contract.resources()
  end

  test "serializers emit exactly the contracted keys" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    deployment = %Deployment{id: 1, app_id: app.id}

    assert keys(Serializer.app(app)) == contract_keys("app")
    assert keys(Serializer.server(server)) == contract_keys("server")
    assert keys(Serializer.user(scope.user)) == contract_keys("user")
    assert keys(Serializer.tenant(scope.tenant)) == contract_keys("tenant")
    assert keys(Serializer.scope(scope)) == contract_keys("me")
    assert keys(Serializer.deployment(deployment)) == contract_keys("deployment")
    assert keys(Serializer.deployment(deployment, log: true)) == contract_keys("deployment_log")
  end

  defp contract_keys(resource), do: resource |> Contract.keys() |> Enum.sort()

  defp keys(map) do
    map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
  end
end
