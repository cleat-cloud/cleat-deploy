defmodule CleatDeploy.Observability.Journal do
  @moduledoc """
  Builds `journalctl` arguments and parses its `-o json` output into entries
  the collector can persist.

  JSON (instead of the `short-iso` text the API returns) is used because it
  carries the journald cursor, priority and unit, which turn deduplication and
  filtering into plain database work.
  """

  @default_tail 500

  @priority_severities %{
    "0" => "emerg",
    "1" => "alert",
    "2" => "crit",
    "3" => "err",
    "4" => "warning",
    "5" => "notice",
    "6" => "info",
    "7" => "debug"
  }

  @type entry :: %{
          cursor: String.t(),
          occurred_at: DateTime.t(),
          severity: String.t(),
          unit: String.t(),
          message: String.t()
        }

  @doc """
  journalctl argv for a collection window.

  `unit` nil or "" reads the whole host journal.
  """
  @spec argv(keyword()) :: [String.t()]
  def argv(opts) do
    unit = opts[:unit]
    tail = opts[:tail] || @default_tail
    since = opts[:since]

    ["sudo", "journalctl"] ++
      if(unit in [nil, ""], do: [], else: ["-u", unit]) ++
      ["-n", Integer.to_string(tail)] ++
      if(since, do: ["--since", since], else: []) ++
      ["--no-pager", "-o", "json", "--utc"]
  end

  @doc """
  Parses newline-delimited journald JSON. Lines that do not decode, or that
  have no usable timestamp, are dropped.
  """
  @spec parse(binary()) :: [entry()]
  def parse(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.flat_map(&parse_line/1)
  end

  defp parse_line(line) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) ->
        case occurred_at(map) do
          nil -> []
          occurred_at -> [entry(map, occurred_at)]
        end

      _ ->
        []
    end
  end

  defp entry(map, occurred_at) do
    %{
      cursor: cursor(map, occurred_at),
      occurred_at: occurred_at,
      severity: severity(map),
      unit: unit(map),
      message: message(map)
    }
  end

  defp cursor(map, occurred_at) do
    case map["__CURSOR"] do
      cursor when is_binary(cursor) and cursor != "" ->
        cursor

      _ ->
        digest = :crypto.hash(:sha256, [DateTime.to_iso8601(occurred_at), message(map)])
        "sha256:" <> Base.encode16(digest, case: :lower)
    end
  end

  defp occurred_at(map) do
    microseconds =
      case map["__REALTIME_TIMESTAMP"] do
        timestamp when is_integer(timestamp) ->
          timestamp

        timestamp when is_binary(timestamp) ->
          case Integer.parse(timestamp) do
            {value, ""} -> value
            _ -> nil
          end

        _ ->
          nil
      end

    with microseconds when is_integer(microseconds) <- microseconds,
         {:ok, datetime} <- DateTime.from_unix(microseconds, :microsecond) do
      DateTime.truncate(datetime, :second)
    else
      _ -> nil
    end
  end

  defp severity(map) do
    Map.get(@priority_severities, priority_key(map["PRIORITY"]), "info")
  end

  defp priority_key(priority) when is_integer(priority), do: Integer.to_string(priority)
  defp priority_key(priority) when is_binary(priority), do: priority
  defp priority_key(_), do: nil

  defp unit(map) do
    ["_SYSTEMD_UNIT", "SYSLOG_IDENTIFIER", "_COMM", "_EXE"]
    |> Enum.find_value("", fn key ->
      case map[key] do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp message(map) do
    case map["MESSAGE"] do
      message when is_binary(message) -> message
      bytes when is_list(bytes) -> bytes_to_string(bytes)
      _ -> ""
    end
  end

  defp bytes_to_string(bytes) do
    binary = :erlang.list_to_binary(bytes)

    case :unicode.characters_to_binary(binary) do
      converted when is_binary(converted) -> converted
      _ -> binary
    end
  rescue
    _ -> ""
  end
end
