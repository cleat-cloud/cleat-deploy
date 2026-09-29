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

  defp stub_collector(enabled) do
    Application.put_env(:cleat_deploy, :log_collector_enabled, enabled)
    on_exit(fn -> Application.put_env(:cleat_deploy, :log_collector_enabled, false) end)
  end
end
