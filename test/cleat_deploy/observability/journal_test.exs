defmodule CleatDeploy.Observability.JournalTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.Observability.Journal

  describe "argv/1" do
    test "reads the whole host journal when the unit is blank" do
      assert Journal.argv(tail: 100) ==
               ["sudo", "journalctl", "-n", "100", "--no-pager", "-o", "json", "--utc"]
    end

    test "filters by unit and since" do
      argv = Journal.argv(unit: "phx-app", tail: 50, since: "2026-09-28 12:00:00")

      assert argv == [
               "sudo",
               "journalctl",
               "-u",
               "phx-app",
               "-n",
               "50",
               "--since",
               "2026-09-28 12:00:00",
               "--no-pager",
               "-o",
               "json",
               "--utc"
             ]
    end
  end

  describe "parse/1" do
    test "parses cursor, timestamp, severity, unit and message" do
      output =
        json([
          %{
            "__CURSOR" => "c-1",
            "__REALTIME_TIMESTAMP" => "1700000000000000",
            "PRIORITY" => "3",
            "_SYSTEMD_UNIT" => "phx-app.service",
            "MESSAGE" => "boom"
          }
        ])

      assert [entry] = Journal.parse(output)
      assert entry.cursor == "c-1"
      assert entry.severity == "err"
      assert entry.unit == "phx-app.service"
      assert entry.message == "boom"
      assert entry.occurred_at == ~U[2023-11-14 22:13:20Z]
    end

    test "accepts integer PRIORITY and REALTIME_TIMESTAMP from journald JSON" do
      output =
        json([
          %{
            "__CURSOR" => "c-int",
            "__REALTIME_TIMESTAMP" => 1_700_000_000_000_000,
            "PRIORITY" => 3,
            "MESSAGE" => "boom"
          }
        ])

      assert [entry] = Journal.parse(output)
      assert entry.severity == "err"
      assert entry.occurred_at == ~U[2023-11-14 22:13:20Z]
    end

    test "decodes byte-list messages and defaults severity to info" do
      output =
        json([
          %{"__REALTIME_TIMESTAMP" => "1700000000000000", "MESSAGE" => [104, 105]}
        ])

      assert [entry] = Journal.parse(output)
      assert entry.message == "hi"
      assert entry.severity == "info"
    end

    test "falls back to a fingerprint cursor when the cursor is missing" do
      output = json([%{"__REALTIME_TIMESTAMP" => "1700000000000000", "MESSAGE" => "x"}])

      assert [entry] = Journal.parse(output)
      assert String.starts_with?(entry.cursor, "sha256:")
    end

    test "drops malformed lines and entries without a timestamp" do
      output =
        [
          "not json",
          Jason.encode!(%{"MESSAGE" => "no timestamp"}),
          Jason.encode!(%{"__REALTIME_TIMESTAMP" => "not-a-number", "MESSAGE" => "bad"})
        ]
        |> Enum.join("\n")

      assert Journal.parse(output) == []
    end
  end

  defp json(maps), do: Enum.map_join(maps, "\n", &Jason.encode!/1)
end
