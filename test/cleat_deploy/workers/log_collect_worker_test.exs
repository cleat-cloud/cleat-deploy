defmodule CleatDeploy.Workers.LogCollectWorkerTest do
  use CleatDeploy.DataCase, async: false

  use Oban.Testing,
    repo: CleatDeploy.Repo,
    notifier: Oban.Notifiers.Isolated,
    testing: :manual

  import Mox

  alias CleatDeploy.Apps.RuntimeLogsMock
  alias CleatDeploy.Observability.LogEvent
  alias CleatDeploy.Repo
  alias CleatDeploy.TenancyFixtures
  alias CleatDeploy.Workers.LogCollectWorker

  setup :verify_on_exit!

  setup do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    app = TenancyFixtures.app_fixture(scope, server)

    stub_collector(false)
    %{scope: scope, server: server, app: app}
  end

  test "does nothing while the collector is disabled" do
    assert :ok = perform_job(LogCollectWorker, %{})
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "collects journal windows and prunes when enabled" do
    stub_collector(true)

    expect(RuntimeLogsMock, :run, fn subject, _argv ->
      assert %CleatDeploy.Servers.Server{id: _} = subject

      timestamp = DateTime.utc_now() |> DateTime.to_unix(:microsecond) |> Integer.to_string()

      {:ok,
       Jason.encode!(%{
         "__CURSOR" => "worker-1",
         "__REALTIME_TIMESTAMP" => timestamp,
         "PRIORITY" => "6",
         "MESSAGE" => "collected",
         "_SYSTEMD_UNIT" => "phx-app.service"
       })}
    end)

    assert :ok = perform_job(LogCollectWorker, %{})

    assert [event] = Repo.all(LogEvent)
    assert event.message == "collected"
    assert event.app_id
  end

  test "collects a single app when app_id is passed", ctx do
    stub_collector(true)
    other = TenancyFixtures.app_fixture(ctx.scope, ctx.server)

    expect(RuntimeLogsMock, :run, fn _subject, _argv ->
      timestamp = DateTime.utc_now() |> DateTime.to_unix(:microsecond) |> Integer.to_string()

      {:ok,
       Jason.encode!(%{
         "__CURSOR" => "one-app",
         "__REALTIME_TIMESTAMP" => timestamp,
         "PRIORITY" => "6",
         "MESSAGE" => "just one",
         "_SYSTEMD_UNIT" => "phx-app.service"
       })}
    end)

    assert :ok = perform_job(LogCollectWorker, %{"app_id" => ctx.app.id})
    assert [event] = Repo.all(LogEvent)
    assert event.app_id == ctx.app.id
    assert event.message == "just one"
    assert other.id != ctx.app.id
  end

  test "skips prune on a per-app collect", ctx do
    stub_collector(true)
    Application.put_env(:cleat_deploy, :log_max_rows_per_tenant, 1)

    on_exit(fn ->
      Application.delete_env(:cleat_deploy, :log_max_rows_per_tenant)
    end)

    now = DateTime.utc_now(:second)

    Repo.insert!(%LogEvent{
      tenant_id: ctx.scope.tenant.id,
      app_id: ctx.app.id,
      server_id: ctx.server.id,
      source: "app",
      unit: "phx-app.service",
      cursor: "old",
      severity: "info",
      message: "old",
      occurred_at: DateTime.add(now, -60, :second)
    })

    Repo.insert!(%LogEvent{
      tenant_id: ctx.scope.tenant.id,
      app_id: ctx.app.id,
      server_id: ctx.server.id,
      source: "app",
      unit: "phx-app.service",
      cursor: "kept",
      severity: "info",
      message: "kept",
      occurred_at: now
    })

    expect(RuntimeLogsMock, :run, fn _subject, _argv ->
      timestamp = DateTime.utc_now() |> DateTime.to_unix(:microsecond) |> Integer.to_string()

      {:ok,
       Jason.encode!(%{
         "__CURSOR" => "fresh-collect",
         "__REALTIME_TIMESTAMP" => timestamp,
         "PRIORITY" => "6",
         "MESSAGE" => "fresh",
         "_SYSTEMD_UNIT" => "phx-app.service"
       })}
    end)

    assert :ok = perform_job(LogCollectWorker, %{"app_id" => ctx.app.id})
    cursors = Repo.all(LogEvent) |> Enum.map(& &1.cursor) |> Enum.sort()
    assert cursors == ["fresh-collect", "kept", "old"]
  end

  defp stub_collector(enabled) do
    Application.put_env(:cleat_deploy, :log_collector_enabled, enabled)
    on_exit(fn -> Application.put_env(:cleat_deploy, :log_collector_enabled, false) end)
  end
end
