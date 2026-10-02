defmodule CleatDeploy.Repo.BusyRetry do
  @moduledoc false

  @max_attempts 8
  @base_ms 25

  def call(fun) when is_function(fun, 0), do: call(fun, 1)

  def busy?(error), do: sqlite_busy?(error)

  defp call(fun, attempt) do
    fun.()
  rescue
    error ->
      if sqlite_busy?(error) and attempt < @max_attempts do
        Process.sleep(trunc(:math.pow(2, attempt - 1) * @base_ms))
        call(fun, attempt + 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp sqlite_busy?(%{message: message}) when is_binary(message) do
    down = String.downcase(message)

    String.contains?(down, "sqlite_busy") or
      String.contains?(down, "database is locked") or
      String.contains?(down, "database busy")
  end

  defp sqlite_busy?(_), do: false
end
