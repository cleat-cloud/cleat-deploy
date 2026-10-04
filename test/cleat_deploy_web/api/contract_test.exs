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

    query = %{
      app_id: app.id,
      slug: app.slug,
      engine: "sqlite",
      columns: ["id"],
      rows: [["1"]],
      truncated: false
    }

    assert keys(Serializer.app_query(query)) == contract_keys("app_query")
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

    trace = %{
      trace_id: "aa",
      root_name: "GET /",
      services: ["web"],
      started_at_unix_nano: 1_000_000_000,
      duration_ns: 1_000_000,
      span_count: 1,
      error: false
    }

    span = %{
      trace_id: "aa",
      span_id: "bb",
      parent_span_id: "",
      name: "GET /",
      kind: "server",
      service_name: "web",
      status_code: "ok",
      start_time_unix_nano: 1_000_000_000,
      duration_ns: 1_000_000,
      depth: 0,
      attributes: %{}
    }

    pages = %{
      app_id: app.id,
      slug: app.slug,
      range: "24h",
      requested: [],
      visited: [],
      pageviews: 0,
      uniques: 0
    }

    assert keys(Serializer.signal_health(health)) == contract_keys("signal_health")
    assert keys(Serializer.signal_metrics(metrics)) == contract_keys("signal_metrics")
    assert keys(Serializer.signal_pages(pages)) == contract_keys("signal_pages")
    assert keys(Serializer.signal_alert(alert)) == contract_keys("signal_alert")
    assert keys(Serializer.signal_incident(incident)) == contract_keys("signal_incident")
    assert keys(Serializer.signal_trace(trace)) == contract_keys("signal_trace")
    assert keys(Serializer.signal_span(span)) == contract_keys("signal_span")

    assert keys(Serializer.signal_service_map(%{nodes: [], edges: []})) ==
             contract_keys("signal_service_map")

    assert keys(
             Serializer.signal_sampling(%{app_id: app.id, slug: app.slug, trace_sample_rate: 0.0})
           ) ==
             contract_keys("signal_sampling")

    detail = %{
      trace: trace,
      spans: [span],
      service_map: %{nodes: [], edges: []},
      logs: []
    }

    assert keys(Serializer.signal_trace_detail(detail)) == contract_keys("signal_trace_detail")
  end

  defp contract_keys(resource), do: resource |> Contract.keys() |> Enum.sort()

  defp keys(map) do
    map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
  end
end
