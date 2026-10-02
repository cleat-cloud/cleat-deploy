defmodule CleatDeploy.SignalsTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps.App
  alias CleatDeploy.Deployments.Deployment
  alias CleatDeploy.Observability.LogEvent
  alias CleatDeploy.Repo
  alias CleatDeploy.Signals
  alias CleatDeploy.TenancyFixtures

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)
    healthy = TenancyFixtures.app_fixture(scope, server)

    %{scope: scope, server: server, app: app, healthy: healthy}
  end

  describe "health_overview/2" do
    test "flags an app as degraded from an error-rate spike without SSH", ctx do
      now = DateTime.utc_now(:second)

      for _ <- 1..6 do
        insert_event(ctx, ctx.app, %{
          severity: "err",
          occurred_at: DateTime.add(now, -60, :second)
        })
      end

      insert_event(ctx, ctx.app, %{
        severity: "err",
        occurred_at: DateTime.add(now, -4_000, :second)
      })

      insert_event(ctx, ctx.healthy, %{
        severity: "info",
        occurred_at: DateTime.add(now, -30, :second)
      })

      rows = Signals.health_overview(ctx.scope, now: now)

      degraded = Enum.find(rows, &(&1.slug == ctx.app.slug))
      healthy = Enum.find(rows, &(&1.slug == ctx.healthy.slug))

      assert degraded.status == :degraded
      assert :error_rate in degraded.reasons
      assert degraded.error_count == 6

      assert healthy.status == :healthy
      assert healthy.reasons == []
    end

    test "does not leak another tenant's error spike", ctx do
      now = DateTime.utc_now(:second)
      other = TenancyFixtures.scope_fixture()
      other_server = TenancyFixtures.server_fixture(other)
      other_app = TenancyFixtures.app_fixture(other, other_server)

      for _ <- 1..6 do
        insert_event(
          %{scope: other, server: other_server},
          other_app,
          %{severity: "err", occurred_at: DateTime.add(now, -60, :second)}
        )
      end

      rows = Signals.health_overview(ctx.scope, now: now)
      refute Enum.any?(rows, &(&1.slug == other_app.slug))
      assert Enum.all?(rows, &(&1.status == :healthy))
    end

    test "overlays the release that preceded the health change", ctx do
      now = DateTime.utc_now(:second)

      insert_deploy(ctx.app,
        git_sha: "aaa1111",
        finished_at: DateTime.add(now, -7_200, :second)
      )

      live =
        insert_deploy(ctx.app,
          git_sha: "bbb2222",
          finished_at: DateTime.add(now, -90, :second)
        )

      for _ <- 1..6 do
        insert_event(ctx, ctx.app, %{
          severity: "err",
          occurred_at: DateTime.add(now, -30, :second)
        })
      end

      rows = Signals.health_overview(ctx.scope, now: now)
      degraded = Enum.find(rows, &(&1.slug == ctx.app.slug))

      assert degraded.status == :degraded
      assert degraded.preceding_release.id == live.id
      assert degraded.preceding_release.git_sha == "bbb2222"
    end

    test "flags a recent failed deploy as degraded, not unavailable", ctx do
      now = DateTime.utc_now(:second)

      failed =
        insert_deploy(ctx.app,
          git_sha: "deadbeef",
          status: :failed,
          finished_at: DateTime.add(now, -120, :second)
        )

      rows = Signals.health_overview(ctx.scope, now: now)
      row = Enum.find(rows, &(&1.slug == ctx.app.slug))

      assert row.status == :degraded
      assert :deploy_failed in row.reasons
      refute :unavailability in row.reasons
      assert row.preceding_release.id == failed.id
    end

    test "does not keep a stale failed deploy as down once it is outside the window", ctx do
      now = DateTime.utc_now(:second)

      insert_deploy(ctx.app,
        git_sha: "deadbeef",
        status: :failed,
        finished_at: DateTime.add(now, -7_200, :second)
      )

      rows = Signals.health_overview(ctx.scope, now: now)
      row = Enum.find(rows, &(&1.slug == ctx.app.slug))

      assert row.status == :healthy
      assert row.reasons == []
    end

    test "a later successful deploy clears deploy_failed", ctx do
      now = DateTime.utc_now(:second)

      insert_deploy(ctx.app,
        git_sha: "deadbeef",
        status: :failed,
        finished_at: DateTime.add(now, -180, :second)
      )

      insert_deploy(ctx.app,
        git_sha: "cafebabe",
        status: :success,
        finished_at: DateTime.add(now, -60, :second)
      )

      rows = Signals.health_overview(ctx.scope, now: now)
      row = Enum.find(rows, &(&1.slug == ctx.app.slug))

      assert row.status == :healthy
      refute :deploy_failed in row.reasons
      refute :unavailability in row.reasons
    end

    test "marks saturation from out-of-memory log lines", ctx do
      now = DateTime.utc_now(:second)

      insert_event(ctx, ctx.app, %{
        severity: "err",
        message: "enospc: no space left on device",
        occurred_at: DateTime.add(now, -20, :second)
      })

      rows = Signals.health_overview(ctx.scope, now: now)
      row = Enum.find(rows, &(&1.slug == ctx.app.slug))

      assert row.status == :degraded
      assert :saturation in row.reasons
    end
  end

  describe "metrics/3" do
    test "returns RED counts, a series and deploy markers for an app", ctx do
      now = DateTime.utc_now(:second)

      deploy =
        insert_deploy(ctx.app,
          git_sha: "cafebabe",
          finished_at: DateTime.add(now, -600, :second)
        )

      for _ <- 1..3 do
        insert_event(ctx, ctx.app, %{
          severity: "err",
          occurred_at: DateTime.add(now, -120, :second)
        })
      end

      insert_event(ctx, ctx.app, %{
        severity: "info",
        occurred_at: DateTime.add(now, -90, :second)
      })

      assert {:ok, metrics} = Signals.metrics(ctx.scope, ctx.app, now: now, range: "1h")

      assert metrics.app_id == ctx.app.id
      assert metrics.slug == ctx.app.slug
      assert metrics.range == "1h"
      assert metrics.red.errors == 3
      assert metrics.red.logs == 4
      assert metrics.red.error_rate == 0.75
      assert metrics.host.restarts == 0
      assert [%{t: _, errors: 3, logs: 4} | _] = metrics.series

      assert [marker] = metrics.deploy_markers
      assert marker.id == deploy.id
      assert marker.git_sha == "cafebabe"
    end

    test "404s via {:error, :not_found} for another tenant's app", ctx do
      other = TenancyFixtures.scope_fixture()
      other_server = TenancyFixtures.server_fixture(other)
      other_app = TenancyFixtures.app_fixture(other, other_server)

      assert {:error, :not_found} = Signals.metrics(ctx.scope, other_app, now: DateTime.utc_now())
    end
  end

  describe "evaluate_alerts/2" do
    setup do
      Application.put_env(:cleat_deploy, :signals_webhook_url, "http://webhook.test/hook")
      Application.put_env(:cleat_deploy, :signals_req_options, plug: {Req.Test, __MODULE__})

      on_exit(fn ->
        Application.delete_env(:cleat_deploy, :signals_webhook_url)
        Application.delete_env(:cleat_deploy, :signals_req_options)
      end)

      :ok
    end

    test "fires the default error_rate rule and posts the webhook once", ctx do
      now = DateTime.utc_now(:second)
      parent = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:webhook, conn.method, Jason.decode!(raw)})
        Req.Test.json(conn, %{ok: true})
      end)

      for _ <- 1..6 do
        insert_event(ctx, ctx.app, %{
          severity: "err",
          occurred_at: DateTime.add(now, -30, :second)
        })
      end

      assert {:ok, [alert]} = Signals.evaluate_alerts(ctx.scope, now: now)
      assert alert.rule == "error_rate"
      assert alert.status == "firing"
      assert alert.app_id == ctx.app.id
      assert alert.channel == "webhook"

      assert_receive {:webhook, "POST", body}
      assert body["event"] == "signal.alert"
      assert body["rule"] == "error_rate"
      assert body["app"]["slug"] == ctx.app.slug

      assert {:ok, []} = Signals.evaluate_alerts(ctx.scope, now: now)
      refute_received {:webhook, _, _}

      [open] = Signals.list_alerts(ctx.scope)
      assert open.id == alert.id
    end

    test "acks a firing alert", ctx do
      now = DateTime.utc_now(:second)
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{ok: true}) end)

      for _ <- 1..6 do
        insert_event(ctx, ctx.app, %{
          severity: "err",
          occurred_at: DateTime.add(now, -30, :second)
        })
      end

      {:ok, [alert]} = Signals.evaluate_alerts(ctx.scope, now: now)
      assert {:ok, acked} = Signals.ack_alert(ctx.scope, alert.id)
      assert acked.status == "acked"
      assert acked.acked_at
    end
  end

  describe "incident/3" do
    test "merges deploys, alerts and error groups into a timeline", ctx do
      now = DateTime.utc_now(:second)
      fp = CleatDeploy.Observability.Fingerprint.of("crash in worker")

      deploy =
        insert_deploy(ctx.app,
          git_sha: "feedface",
          finished_at: DateTime.add(now, -600, :second)
        )

      for _ <- 1..6 do
        insert_event(ctx, ctx.app, %{
          severity: "err",
          message: "crash in worker",
          fingerprint: fp,
          occurred_at: DateTime.add(now, -30, :second)
        })
      end

      {:ok, [alert]} = Signals.evaluate_alerts(ctx.scope, now: now)
      assert {:ok, incident} = Signals.incident(ctx.scope, ctx.app, now: now, range: "24h")

      assert incident.app_id == ctx.app.id
      assert incident.slug == ctx.app.slug

      kinds = Enum.map(incident.events, & &1.kind)
      assert :deploy in kinds
      assert :alert in kinds
      assert :error_group in kinds

      deploy_event = Enum.find(incident.events, &(&1.kind == :deploy))
      assert deploy_event.summary == "feedface"
      assert deploy_event.payload.id == deploy.id

      alert_event = Enum.find(incident.events, &(&1.kind == :alert))
      assert alert_event.payload.id == alert.id
      assert alert_event.payload.rule == "error_rate"

      group = Enum.find(incident.events, &(&1.kind == :error_group))
      assert group.payload.fingerprint == fp
      assert group.payload.count == 6
    end

    test "404s via {:error, :not_found} for another tenant's app", ctx do
      other = TenancyFixtures.scope_fixture()
      other_server = TenancyFixtures.server_fixture(other)
      other_app = TenancyFixtures.app_fixture(other, other_server)

      assert {:error, :not_found} = Signals.incident(ctx.scope, other_app)
    end
  end

  defp insert_deploy(app, attrs) do
    Repo.insert!(%Deployment{
      app_id: app.id,
      git_sha: attrs[:git_sha],
      git_ref: attrs[:git_ref] || "main",
      status: attrs[:status] || :success,
      finished_at: attrs[:finished_at],
      started_at: attrs[:finished_at]
    })
  end

  defp insert_event(ctx, app, attrs) do
    defaults = %{
      tenant_id: ctx.scope.tenant.id,
      app_id: app.id,
      server_id: ctx.server.id,
      source: "app",
      unit: app.systemd_unit || App.default_systemd_unit(app.slug, app.runtime || "phoenix"),
      cursor: "cursor-#{System.unique_integer([:positive])}",
      severity: "info",
      message: "hello",
      occurred_at: DateTime.utc_now(:second)
    }

    Repo.insert!(struct!(LogEvent, Map.merge(defaults, attrs)))
  end
end
