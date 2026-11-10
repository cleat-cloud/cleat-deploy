defmodule CleatDeploy.Signals.ExceptionsTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Observability.{Fingerprint, LogEvent}
  alias CleatDeploy.Repo
  alias CleatDeploy.Signals.{Exceptions, Issues, Traces}
  alias CleatDeploy.TenancyFixtures

  @stack """
  ** (RuntimeError) payment declined
      (my_app 1.0.0) lib/my_app/worker.ex:42: MyApp.Worker.handle_info/2
      (stdlib 6.2) gen_server.erl:1850: :gen_server.try_dispatch/4
  """

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    %{scope: scope, server: server, app: app}
  end

  describe "sampling" do
    test "defaults exception_sample_rate to 0", %{scope: scope, app: app} do
      assert {:ok, sampling} = Traces.get_sampling(scope, app)
      assert sampling.exception_sample_rate == 0.0
      assert sampling.trace_sample_rate == 0.0
    end

    test "persists exception_sample_rate independently of traces", %{scope: scope, app: app} do
      assert {:ok, updated} =
               Traces.set_sampling(scope, app, %{exception_sample_rate: 1.0})

      assert updated.exception_sample_rate == 1.0
      assert updated.trace_sample_rate == 0.0
      assert Repo.get!(App, app.id).exception_sample_rate == 1.0
    end
  end

  describe "ingest/3" do
    test "stores nothing while the default exception sample rate is 0", ctx do
      assert {:ok, %{accepted: 0, dropped: 1}} =
               Exceptions.ingest(ctx.scope, ctx.app, logs_payload())

      assert Repo.all(LogEvent) == []
      assert Issues.list(ctx.scope) == []
    end

    test "opens an issue from OTLP exception attributes when sampling is 1", ctx do
      {:ok, _} = Traces.set_sampling(ctx.scope, ctx.app, %{exception_sample_rate: 1.0})

      assert {:ok, %{accepted: 1, dropped: 0}} =
               Exceptions.ingest(ctx.scope, ctx.app, logs_payload())

      assert [issue] = Issues.list(ctx.scope)
      assert issue.app_id == ctx.app.id
      assert issue.source == "otlp"
      assert issue.status == "unresolved"
      assert issue.sample =~ "RuntimeError"
      assert issue.fingerprint == Fingerprint.of(String.trim(@stack))

      [event] = Repo.all(LogEvent)
      assert event.source == "otlp"
      assert event.severity == "err"
      assert event.app_id == ctx.app.id
      assert event.server_id == ctx.server.id
      assert event.message =~ "payment declined"
      refute event.message =~ "sk-secret"
    end

    test "redacts secrets in the stack before persist", ctx do
      {:ok, _} = Traces.set_sampling(ctx.scope, ctx.app, %{exception_sample_rate: 1.0})
      stack = @stack <> "token=sk-secret\n"

      payload =
        logs_payload(
          type: "RuntimeError",
          message: "token=sk-secret payment declined",
          stack: stack
        )

      assert {:ok, %{accepted: 1, dropped: 0}} = Exceptions.ingest(ctx.scope, ctx.app, payload)

      [event] = Repo.all(LogEvent)
      refute event.message =~ "sk-secret"
      assert event.message =~ "[redacted]"
    end

    test "accepts exception events on OTLP spans", ctx do
      {:ok, _} = Traces.set_sampling(ctx.scope, ctx.app, %{exception_sample_rate: 1.0})

      assert {:ok, %{accepted: 1, dropped: 0}} =
               Exceptions.ingest(ctx.scope, ctx.app, span_exception_payload())

      assert [%{source: "otlp", sample: sample}] = Issues.list(ctx.scope)
      assert sample =~ "RuntimeError"
    end

    test "is idempotent for the same log record", ctx do
      {:ok, _} = Traces.set_sampling(ctx.scope, ctx.app, %{exception_sample_rate: 1.0})

      assert {:ok, %{accepted: 1, dropped: 0}} =
               Exceptions.ingest(ctx.scope, ctx.app, logs_payload())

      assert {:ok, %{accepted: 0, dropped: 0}} =
               Exceptions.ingest(ctx.scope, ctx.app, logs_payload())

      assert [%{count: 1}] = Issues.list(ctx.scope)
      assert Repo.aggregate(LogEvent, :count) == 1
    end

    test "does not leak another tenant's exceptions", ctx do
      {:ok, _} = Traces.set_sampling(ctx.scope, ctx.app, %{exception_sample_rate: 1.0})
      {:ok, _} = Exceptions.ingest(ctx.scope, ctx.app, logs_payload())

      other = TenancyFixtures.scope_fixture()
      other_server = TenancyFixtures.server_fixture(other)
      other_app = TenancyFixtures.app_fixture(other, other_server)
      {:ok, _} = Traces.set_sampling(other, other_app, %{exception_sample_rate: 1.0})

      assert Issues.list(other) == []
      assert [%{app_id: app_id}] = Issues.list(ctx.scope)
      assert app_id == ctx.app.id
    end

    test "rejects a payload without resourceLogs or exception spans", ctx do
      {:ok, _} = Traces.set_sampling(ctx.scope, ctx.app, %{exception_sample_rate: 1.0})
      assert {:error, :invalid_payload} = Exceptions.ingest(ctx.scope, ctx.app, %{"logs" => []})
    end
  end

  defp logs_payload(opts \\ []) do
    type = Keyword.get(opts, :type, "RuntimeError")
    message = Keyword.get(opts, :message, "payment declined")
    stack = Keyword.get(opts, :stack, @stack)

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
                  "body" => %{"stringValue" => message},
                  "attributes" => [
                    %{"key" => "exception.type", "value" => %{"stringValue" => type}},
                    %{"key" => "exception.message", "value" => %{"stringValue" => message}},
                    %{"key" => "exception.stacktrace", "value" => %{"stringValue" => stack}}
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
  end

  defp span_exception_payload do
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
                  "traceId" => "5b8aa5a2d2c872e8321cf37308d69df2",
                  "spanId" => "051581bf3cb55c13",
                  "name" => "Worker.perform",
                  "startTimeUnixNano" => "1544712660000000000",
                  "endTimeUnixNano" => "1544712661000000000",
                  "events" => [
                    %{
                      "name" => "exception",
                      "timeUnixNano" => "1544712660500000000",
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
      ]
    }
  end
end
