defmodule CleatDeploy.Apps.IdleShutdownTest do
  use CleatDeploy.DataCase, async: false

  import Mox

  alias CleatDeploy.Apps.IdleShutdown
  alias CleatDeploy.Apps.IdleShutdownMock
  alias CleatDeploy.Deploy.Wake
  alias CleatDeploy.TenancyFixtures

  setup :verify_on_exit!

  describe "report_script/1" do
    test "reports idle seconds and systemd state for every unit" do
      scope = TenancyFixtures.scope_fixture()
      server = TenancyFixtures.server_fixture(scope)

      alpha =
        TenancyFixtures.app_fixture(scope, server, %{slug: "alpha", systemd_unit: "phx-alpha"})

      beta = TenancyFixtures.app_fixture(scope, server, %{slug: "beta", systemd_unit: "phx-beta"})

      script = IdleShutdown.report_script([alpha, beta])

      assert script =~ "for UNIT in 'phx-alpha' 'phx-beta'; do"
      assert script =~ ~s|STAMP="#{Wake.stamp_dir()}/${UNIT}.stamp"|
      assert script =~ ~s|IDLE=$((NOW - $(stat -c %Y "$STAMP")))|
      assert script =~ ~s|STATE=$(systemctl is-active "$UNIT"|
      assert script =~ ~S(printf 'CLEAT %s %s %s\n')
    end

    test "reports only the HTTP unit of a multi-process app" do
      scope = TenancyFixtures.scope_fixture()
      server = TenancyFixtures.server_fixture(scope)

      app =
        TenancyFixtures.app_fixture(scope, server, %{slug: "multi", systemd_unit: "phx-multi"})
        |> Map.put(:deploy_manifest, %{"units" => ["worker"], "addons" => []})

      script = IdleShutdown.report_script([app])

      # Workers must never sleep: only the unit that serves HTTP is reported (and
      # therefore eligible to be stopped).
      assert script =~ "'phx-multi'"
      refute script =~ "phx-multi-worker"
    end
  end

  describe "parse_report/1" do
    test "keeps idle seconds and state per unit, ignoring noise" do
      output = """
      CLEAT phx-alpha 900 active
      CLEAT phx-beta -1 inactive
      Connection to host closed.
      """

      assert IdleShutdown.parse_report(output) == %{
               "phx-alpha" => %{idle_seconds: 900, state: "active"},
               "phx-beta" => %{idle_seconds: -1, state: "inactive"}
             }
    end
  end

  describe "due?/2" do
    test "is due when the app is running and idle past the window" do
      assert IdleShutdown.due?(%{idle_seconds: 600, state: "active"}, 10)
      refute IdleShutdown.due?(%{idle_seconds: 599, state: "active"}, 10)
    end

    test "is never due for stopped apps, missing stamps, or absent entries" do
      refute IdleShutdown.due?(%{idle_seconds: 99_999, state: "inactive"}, 10)
      refute IdleShutdown.due?(%{idle_seconds: -1, state: "active"}, 10)
      refute IdleShutdown.due?(nil, 10)
    end
  end

  describe "sweep/2" do
    test "stops the idle app and leaves the busy one running" do
      %{idle: idle, busy: busy} = two_apps()

      report = """
      CLEAT phx-idle 1000 active
      CLEAT phx-busy 30 active
      """

      expect(IdleShutdownMock, :run, 2, fn _app, ["bash", "-c", script] ->
        if String.contains?(script, "systemctl stop") do
          assert script == "sudo systemctl stop 'phx-idle'"
          {:ok, ""}
        else
          {:ok, report}
        end
      end)

      assert %{stopped: [stopped], skipped: [skipped]} = IdleShutdown.sweep([idle, busy], 15)
      assert stopped == "idle-app"
      assert skipped == "busy-app"
    end

    test "never stops an app that was not armed for wake-on-request" do
      %{idle: idle, busy: busy} = two_apps()

      expect(IdleShutdownMock, :run, 1, fn _app, ["bash", "-c", script] ->
        refute String.contains?(script, "systemctl stop")
        {:ok, "CLEAT phx-idle -1 active\nCLEAT phx-busy -1 active\n"}
      end)

      assert %{stopped: [], skipped: skipped} = IdleShutdown.sweep([idle, busy], 15)
      assert Enum.sort(skipped) == ["busy-app", "idle-app"]
    end

    test "keeps every app of a server when the report fails" do
      %{idle: idle, busy: busy} = two_apps()

      expect(IdleShutdownMock, :run, 1, fn _app, _argv -> {:error, "ssh: connect refused"} end)

      assert %{stopped: [], skipped: skipped} = IdleShutdown.sweep([idle, busy], 15)
      assert Enum.sort(skipped) == ["busy-app", "idle-app"]
    end

    test "reports the app as skipped when the stop itself fails" do
      %{idle: idle, busy: busy} = two_apps()

      expect(IdleShutdownMock, :run, 2, fn _app, ["bash", "-c", script] ->
        if String.contains?(script, "systemctl stop") do
          {:error, "sudo: a password is required"}
        else
          {:ok, "CLEAT phx-idle 1000 active\nCLEAT phx-busy 1000 active\n"}
        end
      end)

      assert %{stopped: [], skipped: skipped} = IdleShutdown.sweep([idle, busy], 15)
      assert Enum.sort(skipped) == ["busy-app", "idle-app"]
    end

    test "asks for a single report per server" do
      scope = TenancyFixtures.scope_fixture()
      server = TenancyFixtures.server_fixture(scope)

      apps =
        for n <- 1..3 do
          TenancyFixtures.app_fixture(scope, server, %{
            slug: "multi-#{n}",
            systemd_unit: "phx-multi-#{n}"
          })
        end

      expect(IdleShutdownMock, :run, 1, fn _app, ["bash", "-c", _script] ->
        {:ok, "CLEAT phx-multi-1 5 active\n"}
      end)

      assert %{stopped: []} = IdleShutdown.sweep(apps, 15)
    end
  end

  test "unit/1 falls back to the derived systemd unit name" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    app =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "sem-unit",
        runtime: "golang",
        systemd_unit: nil
      })

    assert IdleShutdown.unit(app) == "sem-unit"
  end

  defp two_apps do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    idle =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "idle-app",
        host: "idle.example.com",
        systemd_unit: "phx-idle"
      })

    busy =
      TenancyFixtures.app_fixture(scope, server, %{
        slug: "busy-app",
        host: "busy.example.com",
        systemd_unit: "phx-busy"
      })

    %{idle: idle, busy: busy}
  end
end
