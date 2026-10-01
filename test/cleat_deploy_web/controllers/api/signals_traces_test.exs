defmodule CleatDeployWeb.Api.SignalsTracesTest do
  use CleatDeployWeb.ConnCase, async: false

  alias CleatDeploy.Accounts
  alias CleatDeploy.Observability.LogEvent
  alias CleatDeploy.Repo
  alias CleatDeploy.Signals.Traces
  alias CleatDeploy.TenancyFixtures
  alias CleatDeployWeb.Api.Contract

  @trace_id "5b8aa5a2d2c872e8321cf37308d69df2"
  @root_span "051581bf3cb55c13"

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    {:ok, token, _api_token} = Accounts.create_api_token(scope.user, scope.tenant, %{name: "ci"})

    %{scope: scope, server: server, app: app, token: token}
  end

  test "POST /api/v1/signals/otlp/v1/traces requires a token" do
    conn = post(build_conn(), ~p"/api/v1/signals/otlp/v1/traces", %{})
    assert json_response(conn, 401)["error"] == "missing_bearer_token"
  end

  test "GET /api/v1/signals/traces requires an app", %{token: token} do
    conn = build_conn() |> auth(token) |> get(~p"/api/v1/signals/traces")
    assert json_response(conn, 404)["error"] == "not_found"
  end

  test "ingests OTLP JSON when sampling is 1 and lists traces", %{
    token: token,
    scope: scope,
    app: app
  } do
    {:ok, _} = Traces.set_sampling(scope, app, 1.0)

    conn =
      build_conn()
      |> auth(token)
      |> json_post(~p"/api/v1/signals/otlp/v1/traces?app=#{app.slug}", checkout_payload())

    assert json_response(conn, 202)["data"] == %{"accepted" => 1, "dropped" => 0}

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/signals/traces?app=#{app.slug}")
    [row] = json_response(conn, 200)["data"]

    assert row["trace_id"] == @trace_id
    assert row["root_name"] == "GET /checkout"
    assert row["span_count"] == 1
    assert row["error"] == false

    assert row |> Map.keys() |> Enum.sort() ==
             Contract.keys("signal_trace") |> Enum.sort()
  end

  test "drops OTLP spans while sampling is 0", %{token: token, app: app} do
    conn =
      build_conn()
      |> auth(token)
      |> json_post(~p"/api/v1/signals/otlp/v1/traces?app=#{app.slug}", checkout_payload())

    assert json_response(conn, 202)["data"] == %{"accepted" => 0, "dropped" => 1}

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/signals/traces?app=#{app.slug}")
    assert json_response(conn, 200)["data"] == []
  end

  test "returns a waterfall, service map and correlated logs for a trace", %{
    token: token,
    scope: scope,
    server: server,
    app: app
  } do
    {:ok, _} = Traces.set_sampling(scope, app, 1.0)
    {:ok, _} = Traces.ingest(scope, app, checkout_payload())

    Repo.insert!(%LogEvent{
      tenant_id: scope.tenant.id,
      app_id: app.id,
      server_id: server.id,
      source: "app",
      unit: "phx-#{app.slug}",
      cursor: "cursor-#{System.unique_integer([:positive])}",
      severity: "err",
      message: "boom trace_id=#{@trace_id}",
      occurred_at: DateTime.utc_now(:second)
    })

    conn =
      build_conn()
      |> auth(token)
      |> get(~p"/api/v1/signals/traces?app=#{app.slug}&trace_id=#{@trace_id}")

    data = json_response(conn, 200)["data"]

    assert data |> Map.keys() |> Enum.sort() ==
             Contract.keys("signal_trace_detail") |> Enum.sort()

    assert data["trace"]["trace_id"] == @trace_id
    assert hd(data["spans"])["span_id"] == @root_span
    assert hd(data["spans"])["depth"] == 0

    assert hd(data["spans"]) |> Map.keys() |> Enum.sort() ==
             Contract.keys("signal_span") |> Enum.sort()

    assert data["service_map"] |> Map.keys() |> Enum.sort() ==
             Contract.keys("signal_service_map") |> Enum.sort()

    assert [%{"message" => "boom trace_id=" <> _}] = data["logs"]
  end

  test "reads and updates sampling", %{token: token, app: app} do
    conn = build_conn() |> auth(token) |> get(~p"/api/v1/signals/sampling?app=#{app.slug}")
    data = json_response(conn, 200)["data"]
    assert data["slug"] == app.slug
    assert data["trace_sample_rate"] == 0.0

    assert data |> Map.keys() |> Enum.sort() ==
             Contract.keys("signal_sampling") |> Enum.sort()

    conn =
      build_conn()
      |> auth(token)
      |> json_patch(~p"/api/v1/signals/sampling", %{"app" => app.slug, "rate" => 0.5})

    updated = json_response(conn, 200)["data"]
    assert updated["trace_sample_rate"] == 0.5
  end

  test "rejects a sampling rate outside 0..1", %{token: token, app: app} do
    conn =
      build_conn()
      |> auth(token)
      |> json_patch(~p"/api/v1/signals/sampling", %{"app" => app.slug, "rate" => 2})

    assert json_response(conn, 422)["error"] == "invalid_request"
  end

  test "does not leak another tenant's traces", %{token: token, app: app} do
    other = TenancyFixtures.scope_fixture()
    other_server = TenancyFixtures.server_fixture(other)
    other_app = TenancyFixtures.app_fixture(other, other_server)
    {:ok, _} = Traces.set_sampling(other, other_app, 1.0)
    {:ok, _} = Traces.ingest(other, other_app, checkout_payload())

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/signals/traces?app=#{app.slug}")
    assert json_response(conn, 200)["data"] == []

    conn =
      build_conn()
      |> auth(token)
      |> get(~p"/api/v1/signals/traces?app=#{other_app.slug}")

    assert json_response(conn, 404)["error"] == "not_found"
  end

  defp checkout_payload do
    %{
      "resourceSpans" => [
        %{
          "resource" => %{
            "attributes" => [
              %{"key" => "service.name", "value" => %{"stringValue" => "web"}}
            ]
          },
          "scopeSpans" => [
            %{
              "spans" => [
                %{
                  "traceId" => @trace_id,
                  "spanId" => @root_span,
                  "parentSpanId" => "",
                  "name" => "GET /checkout",
                  "kind" => 2,
                  "startTimeUnixNano" => "1544712660000000000",
                  "endTimeUnixNano" => "1544712661000000000",
                  "status" => %{"code" => 1},
                  "attributes" => []
                }
              ]
            }
          ]
        }
      ]
    }
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp json_post(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp json_patch(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> patch(path, Jason.encode!(body))
  end
end
