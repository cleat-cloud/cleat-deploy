defmodule CleatDeploy.RuntimeLogsFixtures do
  @moduledoc false

  import Mox

  alias CleatDeploy.Apps.RuntimeLogsMock
  alias CleatDeploy.Servers.Server

  @host_lines "2026-09-06T12:00:00Z host started\n2026-09-06T12:00:01Z caddy listening\n"

  @doc """
  Stubs `RuntimeLogsMock` with the canned app and server journal output.
  """
  def stub_success do
    stub(RuntimeLogsMock, :run, fn
      %Server{}, _argv ->
        {:ok, @host_lines}

      app, _argv ->
        unit = app.systemd_unit || "phx-app"

        {:ok,
         """
         2026-09-06T12:00:00Z #{unit} started
         2026-09-06T12:00:01Z #{unit} {"kind":"request","phase":"completed","at":"2026-09-06T12:00:01Z","method":"HEAD","path":"/","status":200,"remote":"142.252.32.8","duration_ms":2.124}
         """}
    end)

    :ok
  end
end
