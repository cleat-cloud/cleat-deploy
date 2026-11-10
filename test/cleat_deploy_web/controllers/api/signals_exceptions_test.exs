defmodule CleatDeployWeb.Api.SignalsExceptionsTest do
  use CleatDeployWeb.ConnCase, async: false

  alias CleatDeploy.Accounts
  alias CleatDeploy.Signals.{Issues, Traces}
  alias CleatDeploy.TenancyFixtures
  alias CleatDeployWeb.Api.Contract

  @stack """
  ** (RuntimeError) payment declined
      (my_app 1.0.0) lib/my_app/worker.ex:42: MyApp.Worker.handle_info/2
  """

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    {:ok, token, _api_token} = Accounts.create_api_token(scope.user, scope.tenant, %{name: "ci"})

    %{scope: scope, server: server, app: app, token: token}
  end

  test "POST /api/v1/signals/otlp/v1/logs requires a token" do
    conn = post(build_conn(), ~p"/api/v1/signals/otlp/v1/logs", %{})
    assert json_response(conn, 401)["error"] == "missing_bearer_token"
  end

  test "drops OTLP exceptions while sampling is 0", %{token: token, app: app} do
    conn =
      build_conn()
      |> auth(token)
      |> json_post(~p"/api/v1/signals/otlp/v1/logs?app=#{app.slug}", logs_payload())

    assert json_response(conn, 202)["data"] == %{"accepted" => 0, "dropped" => 1}

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/signals/issues?app=#{app.slug}")
    assert json_response(conn, 200)["data"] == []
  end

  test "ingests OTLP exceptions when sampling is 1 and opens an issue", %{
    token: token,
    scope: scope,
    app: app
  } do
    {:ok, _} = Traces.set_sampling(scope, app, %{exception_sample_rate: 1.0})

    conn =
      build_conn()
      |> auth(token)
      |> json_post(~p"/api/v1/signals/otlp/v1/logs?app=#{app.slug}", logs_payload())

    assert json_response(conn, 202)["data"] == %{"accepted" => 1, "dropped" => 0}

    conn = build_conn() |> auth(token) |> get(~p"/api/v1/signals/issues?app=#{app.slug}")
    [row] = json_response(conn, 200)["data"]

    assert row["slug"] == app.slug
    assert row["source"] == "otlp"
    assert row["sample"] =~ "RuntimeError"
    assert row["status"] == "unresolved"

    assert [%{source: "otlp"}] = Issues.list(scope)
  end

  test "does not ingest into another tenant's app", %{token: token} do
    other = TenancyFixtures.scope_fixture()
    other_server = TenancyFixtures.server_fixture(other)
    other_app = TenancyFixtures.app_fixture(other, other_server)
    {:ok, _} = Traces.set_sampling(other, other_app, %{exception_sample_rate: 1.0})

    conn =
      build_conn()
      |> auth(token)
      |> json_post(~p"/api/v1/signals/otlp/v1/logs?app=#{other_app.slug}", logs_payload())

    assert json_response(conn, 404)["error"] == "not_found"
    assert Issues.list(other) == []
  end

  test "reads and updates exception sampling without touching traces", %{token: token, app: app} do
    conn = build_conn() |> auth(token) |> get(~p"/api/v1/signals/sampling?app=#{app.slug}")
    data = json_response(conn, 200)["data"]
    assert data["trace_sample_rate"] == 0.0
    assert data["exception_sample_rate"] == 0.0

    assert data |> Map.keys() |> Enum.sort() ==
             Contract.keys("signal_sampling") |> Enum.sort()

    conn =
      build_conn()
      |> auth(token)
      |> json_patch(~p"/api/v1/signals/sampling", %{
        "app" => app.slug,
        "exception_sample_rate" => 1.0
      })

    updated = json_response(conn, 200)["data"]
    assert updated["exception_sample_rate"] == 1.0
    assert updated["trace_sample_rate"] == 0.0
  end

  defp logs_payload do
    %{
      "resourceLogs" => [
        %{
          "resource" => %{
            "attributes" => [
              %{"key" => "service.name", "value" => %{"stringValue" => "web"}}
            ]
          },
          "scopeLogs" => [
            %{
              "logRecords" => [
                %{
                  "timeUnixNano" => "1544712660000000000",
                  "severityText" => "ERROR",
                  "body" => %{"stringValue" => "payment declined"},
                  "attributes" => [
                    %{
                      "key" => "exception.type",
                      "value" => %{"stringValue" => "RuntimeError"}
                    },
                    %{
                      "key" => "exception.message",
                      "value" => %{"stringValue" => "payment declined"}
                    },
                    %{
                      "key" => "exception.stacktrace",
                      "value" => %{"stringValue" => @stack}
                    }
                  ]
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
