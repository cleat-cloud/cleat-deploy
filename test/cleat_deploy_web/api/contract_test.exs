defmodule CleatDeployWeb.Api.ContractTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.Signals.Alert
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

    health = %{
      app_id: app.id,
      slug: app.slug,
      name: app.name,
      status: :healthy,
      reasons: [],
      error_count: 0,
      previous_error_count: 0,
      preceding_release: nil
    }

    metrics = %{
      app_id: app.id,
      slug: app.slug,
      range: "1h",
      red: %{requests: 0, errors: 0, logs: 0, error_rate: 0.0, latency_ms: nil},
      host: %{cpu: nil, memory: nil, disk: nil, restarts: 0},
      series: [],
      deploy_markers: []
    }

    alert = %Alert{
      id: 1,
      app_id: app.id,
      app: app,
      rule: "error_rate",
      status: "firing",
      message: "Taxa de erro subiu",
      channel: "in_app",
      fired_at: DateTime.utc_now(:second),
      acked_at: nil,
      delivered_at: nil
    }

    incident = %{app_id: app.id, slug: app.slug, events: []}

    assert keys(Serializer.signal_health(health)) == contract_keys("signal_health")
    assert keys(Serializer.signal_metrics(metrics)) == contract_keys("signal_metrics")
    assert keys(Serializer.signal_alert(alert)) == contract_keys("signal_alert")
    assert keys(Serializer.signal_incident(incident)) == contract_keys("signal_incident")
  end

  defp contract_keys(resource), do: resource |> Contract.keys() |> Enum.sort()

  defp keys(map) do
    map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
  end
end
