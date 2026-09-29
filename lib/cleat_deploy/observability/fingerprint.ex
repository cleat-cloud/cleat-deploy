defmodule CleatDeploy.Observability.Fingerprint do
  @moduledoc """
  Stable grouping key for similar log lines (pids, ids and numbers stripped).
  """

  @spec of(String.t()) :: String.t()
  def of(message) when is_binary(message) do
    normalized =
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

    :sha256
    |> :crypto.hash(normalized)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  def of(_), do: of("")
end
