defmodule CleatDeploy.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. This project uses SQLite:
  `async: true` is not supported on DataCase (see issue #201).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias CleatDeploy.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import CleatDeploy.DataCase
    end
  end

  setup tags do
    CleatDeploy.DataCase.setup_sandbox(tags)
    Mox.stub(CleatDeploy.Deploy.RunnerMock, :interrupt, fn _app, _deployment -> :ok end)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    if tags[:async] do
      raise ArgumentError, """
      SQLite DataCase/ConnCase tests cannot run with async: true (issue #201).
      Use `async: false`, or ExUnit.Case for tests that do not touch the database.
      """
    end

    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(CleatDeploy.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
