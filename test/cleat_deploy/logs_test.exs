defmodule CleatDeploy.LogsTest do
  use CleatDeploy.DataCase, async: false

  import Mox

  alias CleatDeploy.Apps.RuntimeLogsMock
  alias CleatDeploy.Logs
  alias CleatDeploy.RuntimeLogsFixtures
  alias CleatDeploy.TenancyFixtures

  setup :verify_on_exit!

  setup do
    RuntimeLogsFixtures.stub_success()

    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)
    %{scope: scope, server: server}
  end

  describe "fetch_app/2" do
    test "reads journal lines for the app unit", %{scope: scope, server: server} do
      app =
        TenancyFixtures.app_fixture(scope, server, %{
          slug: "assistente",
          systemd_unit: "assistente"
        })

      assert {:ok, result} = Logs.fetch_app(app, [])
      assert result.unit == "assistente"
      assert length(result.lines) == 2
      assert Enum.any?(result.lines, &String.contains?(&1, "started"))
      assert %DateTime{} = result.fetched_at
    end

    test "greps the returned lines", %{scope: scope, server: server} do
      app =
        TenancyFixtures.app_fixture(scope, server, %{
          slug: "assistente",
          systemd_unit: "assistente"
        })

      assert {:ok, result} = Logs.fetch_app(app, grep: "started")
      assert length(result.lines) == 1
      assert hd(result.lines) =~ "started"
    end

    test "accepts a map of options", %{scope: scope, server: server} do
      app =
        TenancyFixtures.app_fixture(scope, server, %{
          slug: "assistente",
          systemd_unit: "assistente"
        })

      assert {:ok, result} = Logs.fetch_app(app, %{grep: "started"})
      assert result.unit == "assistente"
      assert length(result.lines) == 1
      assert hd(result.lines) =~ "started"
    end

    test "ignores a caller-provided unit override", %{scope: scope, server: server} do
      app =
        TenancyFixtures.app_fixture(scope, server, %{
          slug: "assistente",
          systemd_unit: "assistente"
        })

      expect(RuntimeLogsMock, :run, fn _subject, argv ->
        assert "assistente" in argv
        refute "other" in argv
        {:ok, "2026-09-06T12:00:00Z assistente started\n"}
      end)

      assert {:ok, result} = Logs.fetch_app(app, %{unit: "other"})
      assert result.unit == "assistente"
    end
  end

  describe "fetch_server/2" do
    test "rejects an invalid unit before calling the runner", %{server: server} do
      assert {:error, {:invalid, "invalid unit"}} =
               Logs.fetch_server(server, unit: "bad; rm -rf /")
    end

    test "fetch_server returns host journal lines", %{server: server} do
      assert {:ok, result} = Logs.fetch_server(server, %{})
      assert result.unit == nil
      assert Enum.any?(result.lines, &String.contains?(&1, "host started"))
    end

    test "greps host journal lines", %{server: server} do
      assert {:ok, result} = Logs.fetch_server(server, %{grep: "caddy"})
      assert length(result.lines) == 1
      assert hd(result.lines) =~ "caddy listening"
    end
  end

  describe "normalize/1" do
    test "defaults tail and leaves unit/since/grep nil" do
      assert {:ok, %{unit: nil, since: nil, tail: 200, grep: nil}} = Logs.normalize([])
    end

    test "accepts a map of options" do
      assert {:ok, %{tail: 50, grep: nil}} = Logs.normalize(%{tail: 50})
    end

    test "accepts a numeric string tail" do
      assert {:ok, %{tail: 50}} = Logs.normalize(tail: "50")
    end

    test "accepts boundary tails" do
      assert {:ok, %{tail: 1}} = Logs.normalize(tail: 1)
      assert {:ok, %{tail: 5000}} = Logs.normalize(tail: 5000)
    end

    test "rejects out-of-range or non-numeric tails" do
      assert {:error, {:invalid, message}} = Logs.normalize(tail: 0)
      assert message == "tail must be between 1 and 5000"

      assert {:error, {:invalid, "tail must be between 1 and 5000"}} =
               Logs.normalize(tail: 5001)

      assert {:error, {:invalid, "tail must be between 1 and 5000"}} =
               Logs.normalize(tail: "abc")
    end

    test "accepts valid ISO and relative since formats" do
      # journalctl rejects a bare "2h"; normalize must hand it "-2h".
      assert {:ok, %{since: "-30m"}} = Logs.normalize(since: "30m")
      assert {:ok, %{since: "-2h"}} = Logs.normalize(since: "2h")
      assert {:ok, %{since: "-1d"}} = Logs.normalize(since: "1d")
      assert {:ok, %{since: "-1w"}} = Logs.normalize(since: "1w")
      assert {:ok, %{since: "2026-09-21"}} = Logs.normalize(since: "2026-09-21")
      assert {:ok, %{since: "2026-09-21 14:30"}} = Logs.normalize(since: "2026-09-21 14:30")
      assert {:ok, %{since: "2026-09-21T10:30:15"}} = Logs.normalize(since: "2026-09-21T10:30:15")
    end

    test "rejects invalid since values" do
      assert {:error, {:invalid, message}} = Logs.normalize(since: "yesterday")
      assert message =~ "invalid since"

      assert {:error, {:invalid, _}} = Logs.normalize(since: "5x")
      assert {:error, {:invalid, _}} = Logs.normalize(since: "2026/09/21")
      assert {:error, {:invalid, _}} = Logs.normalize(since: String.duplicate("1", 33))
    end

    test "validates unit against the allowlist" do
      assert {:ok, %{unit: "phx-app_1.2@x:y"}} = Logs.normalize(unit: "phx-app_1.2@x:y")
      assert {:ok, %{unit: unit}} = Logs.normalize(unit: String.duplicate("a", 128))
      assert byte_size(unit) == 128
      assert {:error, {:invalid, "invalid unit"}} = Logs.normalize(unit: "atelie; rm -rf /")
      assert {:error, {:invalid, "invalid unit"}} = Logs.normalize(unit: "")

      assert {:error, {:invalid, "invalid unit"}} =
               Logs.normalize(unit: String.duplicate("a", 129))
    end

    test "accepts a grep of exactly the maximum length" do
      grep = String.duplicate("a", 200)
      assert {:ok, %{grep: ^grep}} = Logs.normalize(grep: grep)
    end

    test "rejects an over-long grep" do
      assert {:error, {:invalid, "grep is too long"}} =
               Logs.normalize(grep: String.duplicate("a", 201))
    end

    test "rejects a non-binary grep" do
      assert {:error, {:invalid, "grep must be a string"}} = Logs.normalize(grep: 123)
    end
  end

  describe "argv_for/1" do
    test "includes unit, tail and since" do
      normalized = %{unit: "phx-app", since: "-2h", tail: 100, grep: "x"}

      assert Logs.argv_for(normalized) == [
               "sudo",
               "journalctl",
               "-u",
               "phx-app",
               "-n",
               "100",
               "--since",
               "-2h",
               "--no-pager",
               "-o",
               "short-iso",
               "--utc"
             ]
    end

    test "omits unit and since when nil" do
      normalized = %{unit: nil, since: nil, tail: 200, grep: nil}

      assert Logs.argv_for(normalized) == [
               "sudo",
               "journalctl",
               "-n",
               "200",
               "--no-pager",
               "-o",
               "short-iso",
               "--utc"
             ]
    end
  end
end
