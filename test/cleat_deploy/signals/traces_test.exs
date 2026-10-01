defmodule CleatDeploy.Signals.TracesTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Observability.LogEvent
  alias CleatDeploy.Repo
  alias CleatDeploy.Signals.Traces
  alias CleatDeploy.TenancyFixtures

  @trace_id "5b8aa5a2d2c872e8321cf37308d69df2"
  @root_span "051581bf3cb55c13"
  @child_span "5fb8a98c0bec6479"

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    %{scope: scope, server: server, app: app}
  end

  describe "set_sampling/3" do
    test "defaults to 0 and persists a rate between 0 and 1", %{scope: scope, app: app} do
      assert {:ok, sampling} = Traces.get_sampling(scope, app)
      assert sampling.trace_sample_rate == 0.0

      assert {:ok, updated} = Traces.set_sampling(scope, app, 0.25)
      assert updated.trace_sample_rate == 0.25
      assert Repo.get!(App, app.id).trace_sample_rate == 0.25
    end

    test "rejects a rate outside 0..1", %{scope: scope, app: app} do
      assert {:error, changeset} = Traces.set_sampling(scope, app, 1.5)
      assert %{trace_sample_rate: _} = errors_on(changeset)
      assert Repo.get!(App, app.id).trace_sample_rate in [0.0, 0, nil]
    end
  end

  describe "ingest/3" do
    test "stores nothing while the default sample rate is 0", ctx do
      assert {:ok, %{accepted: 0, dropped: 2}} =
               Traces.ingest(ctx.scope, ctx.app, checkout_payload())

      assert Traces.list(ctx.scope, ctx.app) == []
    end

    test "stores OTLP JSON spans when the sample rate is 1", ctx do
      {:ok, _} = Traces.set_sampling(ctx.scope, ctx.app, 1.0)

      assert {:ok, %{accepted: 2, dropped: 0}} =
               Traces.ingest(ctx.scope, ctx.app, checkout_payload())

      [trace] = Traces.list(ctx.scope, ctx.app)
      assert trace.trace_id == @trace_id
      assert trace.root_name == "GET /checkout"
      assert Enum.sort(trace.services) == ["api", "web"]
      assert trace.span_count == 2
      assert trace.error == false
      assert trace.duration_ns == 1_000_000_000
    end

    test "is idempotent for the same trace and span ids", ctx do
      {:ok, _} = Traces.set_sampling(ctx.scope, ctx.app, 1.0)

      assert {:ok, %{accepted: 2, dropped: 0}} =
               Traces.ingest(ctx.scope, ctx.app, checkout_payload())

      assert {:ok, %{accepted: 0, dropped: 0}} =
               Traces.ingest(ctx.scope, ctx.app, checkout_payload())

      assert [%{span_count: 2}] = Traces.list(ctx.scope, ctx.app)
    end

    test "sampling is deterministic for a given trace id", ctx do
      {:ok, _} = Traces.set_sampling(ctx.scope, ctx.app, 0.5)
      first = Traces.ingest(ctx.scope, ctx.app, checkout_payload())
      Repo.delete_all(CleatDeploy.Signals.Span)
      second = Traces.ingest(ctx.scope, ctx.app, checkout_payload())
      assert first == second
    end

    test "does not leak another tenant's traces", ctx do
      {:ok, _} = Traces.set_sampling(ctx.scope, ctx.app, 1.0)
      {:ok, _} = Traces.ingest(ctx.scope, ctx.app, checkout_payload())

      other = TenancyFixtures.scope_fixture()
      other_server = TenancyFixtures.server_fixture(other)
      other_app = TenancyFixtures.app_fixture(other, other_server)
      {:ok, _} = Traces.set_sampling(other, other_app, 1.0)

      assert Traces.list(other, other_app) == []
      assert [%{trace_id: @trace_id}] = Traces.list(ctx.scope, ctx.app)
    end

    test "rejects a payload without resourceSpans", ctx do
      {:ok, _} = Traces.set_sampling(ctx.scope, ctx.app, 1.0)
      assert {:error, :invalid_payload} = Traces.ingest(ctx.scope, ctx.app, %{"spans" => []})
    end
  end

  describe "waterfall/3" do
    test "orders children under their parent with depth", ctx do
      {:ok, _} = Traces.set_sampling(ctx.scope, ctx.app, 1.0)
      {:ok, _} = Traces.ingest(ctx.scope, ctx.app, checkout_payload())

      assert {:ok, waterfall} = Traces.waterfall(ctx.scope, ctx.app, @trace_id)

      assert Enum.map(waterfall.spans, &{&1.span_id, &1.depth, &1.name}) == [
               {@root_span, 0, "GET /checkout"},
               {@child_span, 1, "SELECT orders"}
             ]
    end
  end

  describe "service_map/2" do
    test "builds edges from parent/child services and peer.service", ctx do
      {:ok, _} = Traces.set_sampling(ctx.scope, ctx.app, 1.0)
      {:ok, _} = Traces.ingest(ctx.scope, ctx.app, checkout_payload())

      map = Traces.service_map(ctx.scope, ctx.app)
      assert Enum.sort(Enum.map(map.nodes, & &1.service)) == ["api", "postgres", "web"]

      edges = MapSet.new(Enum.map(map.edges, &{&1.from, &1.to, &1.count}))
      assert MapSet.member?(edges, {"web", "api", 1})
      assert MapSet.member?(edges, {"api", "postgres", 1})
    end
  end

  describe "logs/3" do
    test "finds log lines that mention the trace id", ctx do
      {:ok, _} = Traces.set_sampling(ctx.scope, ctx.app, 1.0)
      {:ok, _} = Traces.ingest(ctx.scope, ctx.app, checkout_payload())

      insert_log(ctx, "request failed trace_id=#{@trace_id}")
      insert_log(ctx, "unrelated")

      logs = Traces.logs(ctx.scope, ctx.app, @trace_id)
      assert Enum.map(logs, & &1.message) == ["request failed trace_id=#{@trace_id}"]
    end
  end

  describe "list/3" do
    test "filters traces by service name", ctx do
      {:ok, _} = Traces.set_sampling(ctx.scope, ctx.app, 1.0)
      {:ok, _} = Traces.ingest(ctx.scope, ctx.app, checkout_payload())
      {:ok, _} = Traces.ingest(ctx.scope, ctx.app, isolated_payload())

      only_web = Traces.list(ctx.scope, ctx.app, service: "web")
      assert Enum.map(only_web, & &1.trace_id) == [@trace_id]

      only_worker = Traces.list(ctx.scope, ctx.app, service: "worker")
      assert Enum.map(only_worker, & &1.trace_id) == ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
    end
  end

  defp checkout_payload do
    %{
      "resourceSpans" => [
        resource_spans("web", [
          span(%{
            "spanId" => @root_span,
            "name" => "GET /checkout",
            "kind" => 2,
            "startTimeUnixNano" => "1544712660000000000",
            "endTimeUnixNano" => "1544712661000000000"
          })
        ]),
        resource_spans("api", [
          span(%{
            "spanId" => @child_span,
            "parentSpanId" => @root_span,
            "name" => "SELECT orders",
            "kind" => 3,
            "startTimeUnixNano" => "1544712660200000000",
            "endTimeUnixNano" => "1544712660500000000",
            "attributes" => [
              %{
                "key" => "peer.service",
                "value" => %{"stringValue" => "postgres"}
              }
            ]
          })
        ])
      ]
    }
  end

  defp isolated_payload do
    %{
      "resourceSpans" => [
        resource_spans("worker", [
          span(%{
            "traceId" => "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "spanId" => "bbbbbbbbbbbbbbbb",
            "name" => "job.run",
            "kind" => 1,
            "startTimeUnixNano" => "1544712662000000000",
            "endTimeUnixNano" => "1544712663000000000"
          })
        ])
      ]
    }
  end

  defp resource_spans(service, spans) do
    %{
      "resource" => %{
        "attributes" => [
          %{"key" => "service.name", "value" => %{"stringValue" => service}}
        ]
      },
      "scopeSpans" => [%{"spans" => spans}]
    }
  end

  defp span(attrs) do
    Map.merge(
      %{
        "traceId" => @trace_id,
        "parentSpanId" => "",
        "status" => %{"code" => 1},
        "attributes" => []
      },
      attrs
    )
  end

  defp insert_log(ctx, message) do
    Repo.insert!(%LogEvent{
      tenant_id: ctx.scope.tenant.id,
      app_id: ctx.app.id,
      server_id: ctx.server.id,
      source: "app",
      unit: ctx.app.systemd_unit || App.default_systemd_unit(ctx.app.slug, ctx.app.runtime),
      cursor: "cursor-#{System.unique_integer([:positive])}",
      severity: "err",
      message: message,
      occurred_at: DateTime.utc_now(:second)
    })
  end
end
