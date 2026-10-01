defmodule CleatDeploy.Apps.RuntimeMemoryArgvCapture do
  @moduledoc false
  @behaviour CleatDeploy.Apps.RuntimeMemory

  @table :runtime_memory_argv_capture

  def take do
    ensure_table()
    argv = :ets.lookup_element(@table, :argv, 2)
    :ets.insert(@table, {:argv, []})
    Enum.reverse(argv)
  end

  @impl true
  def run(app, argv) when is_list(argv) do
    ensure_table()
    current = :ets.lookup_element(@table, :argv, 2)
    :ets.insert(@table, {:argv, [argv | current]})
    CleatDeploy.Apps.RuntimeMemoryStub.run(app, argv)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, {:heir, self(), nil}])
        :ets.insert(@table, {:argv, []})

      _ ->
        :ok
    end
  end
end
