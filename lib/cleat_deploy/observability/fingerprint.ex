defmodule CleatDeploy.Observability.Fingerprint do
  @moduledoc """
  Stable grouping key for similar log lines.

  Stack-aware when the message looks like an Elixir, Node, Python or Go
  crash: the key is exception type plus frames (file + function, line
  numbers dropped). Other lines still hash a normalized message (pids,
  ids and numbers stripped).
  """

  @max_frames 8
  @title_bytes 240

  @spec of(String.t()) :: String.t()
  def of(message) when is_binary(message) do
    digest(stack_key(message) || normalize(message))
  end

  def of(_), do: of("")

  @doc "Exception headline used as the group sample."
  @spec title(String.t()) :: String.t()
  def title(message) when is_binary(message) do
    message
    |> headline()
    |> String.slice(0, @title_bytes)
  end

  def title(_), do: ""

  @doc "True when the line is an exception, panic, segfault or logger error."
  @spec exception?(String.t()) :: boolean()
  def exception?(message) when is_binary(message) do
    stack_key(message) != nil or error_prefix?(message)
  end

  def exception?(_), do: false

  defp stack_key(message) do
    frames = frames(message)
    kind = exception_kind(message)

    cond do
      frames != [] ->
        encoded =
          frames
          |> Enum.take(@max_frames)
          |> Enum.map(&"#{&1.file}|#{&1.function}")
          |> Enum.join(";")

        "stack|#{kind || "unknown"}|#{encoded}"

      kind ->
        "kind|#{kind}|#{normalize(headline(message))}"

      true ->
        nil
    end
  end

  defp exception_kind(message) do
    cond do
      match = Regex.run(~r/\*\* \(([^)]+)\)/, message) ->
        Enum.at(match, 1)

      String.match?(message, ~r/^panic:/m) ->
        "panic"

      String.match?(message, ~r/^segfault\b/mi) ->
        "segfault"

      match = Regex.run(~r/^(\w+(?:Error|Exception|Exit|Panic)):/m, message) ->
        Enum.at(match, 1)

      String.match?(message, ~r/^Traceback \(most recent call last\):/m) ->
        "traceback"

      true ->
        nil
    end
  end

  defp frames(message) do
    elixir_frames(message) ++ node_frames(message) ++ python_frames(message) ++ go_frames(message)
  end

  defp elixir_frames(message) do
    packaged = ~r/^\s+\([^)]+\)\s+(\S+):(\d+):\s+(\S+)\s*$/m
    bare = ~r/^\s{2,}(\S+\.\w+):(\d+):\s+(\S+)\s*$/m

    (Regex.scan(packaged, message) ++ Regex.scan(bare, message))
    |> Enum.map(fn [_, file, _line, function] -> %{file: file, function: function} end)
    |> Enum.uniq()
  end

  defp node_frames(message) do
    regex = ~r/^\s+at\s+(?:(.+?)\s+\()?((?:node:)?[^:)\s]+):(\d+)(?::\d+)?\)?\s*$/m

    Regex.scan(regex, message)
    |> Enum.map(fn
      [_, function, file, _line] -> %{file: file, function: String.trim(function)}
      [_, file, _line] -> %{file: file, function: ""}
    end)
  end

  defp python_frames(message) do
    regex = ~r/^\s+File "([^"]+)", line \d+(?:, in (.+))?/m

    Regex.scan(regex, message)
    |> Enum.map(fn
      [_, file, function] -> %{file: file, function: function}
      [_, file] -> %{file: file, function: ""}
    end)
  end

  defp go_frames(message) do
    regex = ~r/^(\S+)\([^)]*\)\n\t([^:]+):\d+/m

    Regex.scan(regex, message)
    |> Enum.map(fn [_, function, file] -> %{file: file, function: function} end)
  end

  defp headline(message) do
    lines = message |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    Enum.find_value(lines, fn line ->
      cond do
        String.starts_with?(line, "** (") -> line
        String.starts_with?(line, "panic:") -> line
        String.match?(line, ~r/^segfault\b/i) -> line
        String.match?(line, ~r/^(?:[A-Za-z]+)?(?:Error|Exception|Exit|Panic):/) -> line
        true -> nil
      end
    end) || List.first(lines) || ""
  end

  defp error_prefix?(message) do
    String.match?(message, ~r/\[error\]/i) or String.match?(message, ~r/\bconsole\.error\b/i)
  end

  defp normalize(message) do
    message
    |> String.downcase()
    |> String.replace(~r/#pid<[^>]+>/i, "#pid")
    |> String.replace(
      ~r/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/,
      "#id"
    )
    |> String.replace(~r/\b[0-9a-f]{16,}\b/, "#hex")
    |> String.replace(~r/\d+/, "#")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp digest(normalized) do
    :sha256
    |> :crypto.hash(normalized)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end
end
