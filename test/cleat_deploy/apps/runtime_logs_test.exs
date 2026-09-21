defmodule CleatDeploy.Apps.RuntimeLogsTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Apps.RuntimeLogs
  alias CleatDeploy.RuntimeLogsFixtures
  alias CleatDeploy.TenancyFixtures

  setup do
    RuntimeLogsFixtures.stub_success()

    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    %{scope: scope, server: server}
  end

  test "reads journal lines for a valid systemd unit", %{scope: scope, server: server} do
    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "assistente",
        systemd_unit: "assistente"
      })

    assert {:ok, result} = RuntimeLogs.fetch(app)
    assert result.unit == "assistente"

    assert result.lines == [
             "2026-09-06T12:00:00Z assistente started",
             ~s(2026-09-06T12:00:01Z assistente {"kind":"request","phase":"completed","at":"2026-09-06T12:00:01Z","method":"HEAD","path":"/","status":200,"remote":"142.252.32.8","duration_ms":2.124})
           ]

    assert %DateTime{} = result.fetched_at
  end

  test "rejects unsafe systemd unit names", %{scope: scope, server: server} do
    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "evil",
        systemd_unit: "atelie; rm -rf /"
      })

    assert {:error, message} = RuntimeLogs.fetch(app)
    assert message =~ "systemd unit"
  end
end
