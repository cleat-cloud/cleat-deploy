defmodule CleatDeploy.Apps.RuntimeLogsStub do
  @moduledoc false
  @behaviour CleatDeploy.Apps.RuntimeLogs

  @impl true
  def run(%CleatDeploy.Servers.Server{host_ip: _}, _argv) do
    {:ok, "2026-09-06T12:00:00Z host started\n2026-09-06T12:00:01Z caddy listening\n"}
  end

  def run(app, _argv) do
    unit = app.systemd_unit || "phx-app"

    {:ok,
     """
     2026-09-06T12:00:00Z #{unit} started
     2026-09-06T12:00:01Z #{unit} {"kind":"request","phase":"completed","at":"2026-09-06T12:00:01Z","method":"HEAD","path":"/","status":200,"remote":"142.252.32.8","duration_ms":2.124}
     """}
  end
end
