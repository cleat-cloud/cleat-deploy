defmodule CleatDeploy.SqliteAsyncGuardTest do
  @moduledoc """
  SQLite cannot isolate Ecto sandbox owners the way Postgres can. A
  DataCase/ConnCase test with `async: true` shares the same file as the
  rest of the suite and intermittently raises `Exqlite.Error: Database busy`
  (issue #201).
  """

  use ExUnit.Case, async: true

  @db_cases ~w(CleatDeploy.DataCase CleatDeployWeb.ConnCase)

  test "DataCase and ConnCase tests are not async" do
    offenders =
      "test"
      |> Path.join("**/*_test.exs")
      |> Path.wildcard()
      |> Enum.flat_map(&async_db_case_lines/1)

    assert offenders == [],
           """
           SQLite tests must not use DataCase/ConnCase with async: true.
           Keep ExUnit.Case async for code that does not touch the database.

           #{Enum.join(offenders, "\n")}
           """
  end

  defp async_db_case_lines(path) do
    path
    |> File.stream!()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, n} ->
      if db_case_async?(line) do
        ["#{path}:#{n}: #{String.trim(line)}"]
      else
        []
      end
    end)
  end

  defp db_case_async?(line) do
    Enum.any?(@db_cases, &String.contains?(line, "use #{&1}")) and
      String.contains?(line, "async: true")
  end
end
