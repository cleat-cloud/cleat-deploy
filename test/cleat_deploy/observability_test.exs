defmodule CleatDeploy.ObservabilityTest do
  use CleatDeploy.DataCase, async: false

  import Mox

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Apps.RuntimeLogsMock
  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.Observability
  alias CleatDeploy.Observability.LogEvent
  alias CleatDeploy.Repo
  alias CleatDeploy.Servers.Server
  alias CleatDeploy.TenancyFixtures

  setup :verify_on_exit!

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)

    %{scope: scope, server: server, app: app}
  end

  describe "ingest_app/1" do
    test "persists entries with tenant, app, server, deployment and unit", ctx do
      deployment =
        Repo.insert!(%Deployment{app_id: ctx.app.id, git_sha: "abc123", status: :success})

      expect(RuntimeLogsMock, :run, fn %Server{}, argv ->
        assert "-u" in argv
        {:ok, journal([entry("c1", "3", "boom"), entry("c2", "6", "all good")])}
      end)

      assert {:ok, 2} = Observability.ingest_app(ctx.app)

      events = Repo.all(LogEvent) |> Enum.sort_by(& &1.cursor)
      assert [first, second] = events

      assert first.severity == "err"
      assert first.message == "boom"
      assert first.tenant_id == ctx.scope.tenant.id
      assert first.app_id == ctx.app.id
      assert first.server_id == ctx.server.id
      assert first.deployment_id == deployment.id
      assert first.source == "app"
      assert first.unit == expected_unit(ctx.app)
      assert second.severity == "info"
    end

    test "re-ingesting the same window is a no-op", ctx do
      expect(RuntimeLogsMock, :run, fn %Server{}, _argv ->
        {:ok, journal([entry("c1", "6", "hi")])}
      end)

      expect(RuntimeLogsMock, :run, fn %Server{}, _argv ->
        {:ok, journal([entry("c1", "6", "hi")])}
      end)

      assert {:ok, 1} = Observability.ingest_app(ctx.app)
      assert {:ok, 0} = Observability.ingest_app(ctx.app)
      assert Repo.aggregate(LogEvent, :count) == 1
    end

    test "returns the runtime error when the server is unreachable", ctx do
      expect(RuntimeLogsMock, :run, fn %Server{}, _argv -> {:error, "ssh down"} end)

      assert {:error, "ssh down"} = Observability.ingest_app(ctx.app)
      assert Repo.aggregate(LogEvent, :count) == 0
    end
  end

  describe "ingest_server/2" do
    test "keeps each entry's own unit for host-wide reads", ctx do
      expect(RuntimeLogsMock, :run, fn %Server{}, argv ->
        refute "-u" in argv
        {:ok, journal([entry("h1", "4", "disk almost full", "caddy.service")])}
      end)

      assert {:ok, 1} = Observability.ingest_server(ctx.server)

      event = Repo.one(LogEvent)
      assert event.unit == "caddy.service"
      assert event.source == "server"
      assert event.app_id == nil
      assert event.severity == "warning"
    end
  end

  describe "search/2" do
    test "returns the tenant's events, newest first", ctx do
      old = event(ctx, %{cursor: "old", occurred_at: ~U[2026-09-01 10:00:00Z]})
      new = event(ctx, %{cursor: "new", occurred_at: ~U[2026-09-02 10:00:00Z]})

      assert [first, second] = Observability.search(ctx.scope)
      assert first.id == new.id
      assert second.id == old.id
    end

    test "filters by app, severity, min severity and text", ctx do
      event(ctx, %{cursor: "a", severity: "err", message: "Database timeout"})
      event(ctx, %{cursor: "b", severity: "info", message: "request completed"})
      other_app = TenancyFixtures.app_fixture(ctx.scope, ctx.server)
      event(ctx, %{cursor: "c", severity: "err", message: "boom", app_id: other_app.id})

      assert ["a"] =
               Observability.search(ctx.scope, %{app_id: ctx.app.id, min_severity: "warning"})
               |> Enum.map(& &1.cursor)

      assert ["b"] = Observability.search(ctx.scope, %{severity: "info"}) |> Enum.map(& &1.cursor)
      assert ["a"] = Observability.search(ctx.scope, %{q: "timeout"}) |> Enum.map(& &1.cursor)

      assert ["c"] =
               Observability.search(ctx.scope, %{app_id: other_app.id}) |> Enum.map(& &1.cursor)
    end

    test "filters by time window and limit", ctx do
      event(ctx, %{cursor: "old", occurred_at: ~U[2026-09-01 10:00:00Z]})
      event(ctx, %{cursor: "mid", occurred_at: ~U[2026-09-05 10:00:00Z]})
      event(ctx, %{cursor: "new", occurred_at: ~U[2026-09-09 10:00:00Z]})

      assert [%{cursor: "mid"}] =
               Observability.search(ctx.scope, %{
                 since: ~U[2026-09-05 00:00:00Z],
                 until: ~U[2026-09-06 00:00:00Z]
               })

      assert [%{cursor: "new"}] = Observability.search(ctx.scope, %{limit: 1})
    end

    test "never returns another tenant's events", ctx do
      other_scope = TenancyFixtures.scope_fixture()
      other_server = TenancyFixtures.server_fixture(other_scope)
      other_app = TenancyFixtures.app_fixture(other_scope, other_server)

      event(ctx, %{cursor: "mine"})
      insert_event(other_scope.tenant.id, other_app, other_server, %{cursor: "secret"})

      assert Observability.search(ctx.scope) |> Enum.map(& &1.cursor) == ["mine"]
      assert Observability.search(other_scope) |> Enum.map(& &1.cursor) == ["secret"]
    end
  end

  describe "parse_time/1" do
    test "accepts ISO 8601, plain dates and relative windows" do
      assert {:ok, ~U[2026-09-21 12:30:00Z]} = Observability.parse_time("2026-09-21T12:30:00Z")
      assert {:ok, ~U[2026-09-21 12:30:00Z]} = Observability.parse_time("2026-09-21 12:30:00")
      assert {:ok, ~U[2026-09-21 00:00:00Z]} = Observability.parse_time("2026-09-21")

      {:ok, two_hours_ago} = Observability.parse_time("2h")
      delta = DateTime.diff(DateTime.utc_now(:second), two_hours_ago)
      assert_in_delta delta, 7_200, 5
    end

    test "rejects garbage" do
      assert {:error, :invalid} = Observability.parse_time("yesterday")
    end
  end

  describe "parse_limit/1" do
    test "defaults, coerces and bounds the limit" do
      assert {:ok, 200} = Observability.parse_limit(nil)
      assert {:ok, 50} = Observability.parse_limit("50")
      assert {:error, :invalid} = Observability.parse_limit("0")
      assert {:error, :invalid} = Observability.parse_limit("1001")
    end
  end

  describe "prune/1" do
    test "drops events older than the retention window", ctx do
      stale = DateTime.add(DateTime.utc_now(:second), -10 * 86_400, :second)
      event(ctx, %{cursor: "stale", occurred_at: stale})
      event(ctx, %{cursor: "fresh"})

      assert {:ok, 1} = Observability.prune(retention_days: 7)
      assert Observability.search(ctx.scope) |> Enum.map(& &1.cursor) == ["fresh"]
    end

    test "trims each tenant to the row cap", ctx do
      now = DateTime.utc_now(:second)
      event(ctx, %{cursor: "one", occurred_at: DateTime.add(now, -120, :second)})
      event(ctx, %{cursor: "two", occurred_at: now})

      assert {:ok, 1} = Observability.prune(max_rows_per_tenant: 1)
      assert Observability.search(ctx.scope) |> Enum.map(& &1.cursor) == ["two"]
    end
  end

  defp event(ctx, attrs) do
    insert_event(ctx.scope.tenant.id, ctx.app, ctx.server, attrs)
  end

  defp insert_event(tenant_id, app, server, attrs) do
    defaults = %{
      tenant_id: tenant_id,
      app_id: app.id,
      server_id: server.id,
      source: "app",
      unit: expected_unit(app),
      cursor: "cursor-#{System.unique_integer([:positive])}",
      severity: "info",
      message: "hello",
      occurred_at: DateTime.utc_now(:second)
    }

    Repo.insert!(struct!(LogEvent, Map.merge(defaults, attrs)))
  end

  defp expected_unit(app) do
    app.systemd_unit || App.default_systemd_unit(app.slug, app.runtime || "phoenix")
  end

  defp journal(entries), do: Enum.map_join(entries, "\n", &Jason.encode!/1)

  defp entry(cursor, priority, message, unit \\ "phx-app.service") do
    %{
      "__CURSOR" => cursor,
      "__REALTIME_TIMESTAMP" => "1700000000000000",
      "PRIORITY" => priority,
      "MESSAGE" => message,
      "_SYSTEMD_UNIT" => unit
    }
  end
end
