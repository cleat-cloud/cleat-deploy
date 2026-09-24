defmodule CleatDeploy.Repo.BusyRetryTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.Repo.BusyRetry

  test "retries SQLITE_BUSY then returns the successful value" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    result =
      BusyRetry.call(fn ->
        n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

        if n < 3 do
          raise %EctoLibSql.Error{
            message: ~s(Execute failed: SQLite error: database is locked, code: "SQLITE_BUSY")
          }
        else
          :staged
        end
      end)

    assert result == :staged
    assert Agent.get(counter, & &1) == 3
  end

  test "reraises errors that are not SQLITE_BUSY" do
    assert_raise RuntimeError, "boom", fn ->
      BusyRetry.call(fn -> raise "boom" end)
    end
  end
end
