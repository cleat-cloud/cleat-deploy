defmodule CleatDeploy.Analytics.Summary do
  @moduledoc """
  Reads sidecar pageview summaries over loopback or SSH. Never writes pageviews.

  `visited/1` caches `{server_id, :visited}` for 60s. HTTP errors return
  `{:ok, rows, stale: true}` when a cache entry exists, otherwise `{:ok, []}`.
  `app/3` is not cached.
  """

  alias CleatDeploy.Analytics.SummaryStub

  @table __MODULE__
  @ttl_ms 60_000

  def visited(server) do
    client = client()

    if client == SummaryStub do
      client.visited(server)
    else
      cached({server_id(server), :visited}, fn -> client.visited(server) end)
    end
  end

  def app(server, host, range) when is_binary(host) and is_binary(range) do
    client().app(server, host, range)
  end

  defp cached(key, fun) when is_function(fun, 0) do
    ensure_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, inserted_at}] when now - inserted_at < @ttl_ms ->
        {:ok, value}

      existing ->
        case fun.() do
          {:ok, value} ->
            :ets.insert(@table, {key, value, now})
            {:ok, value}

          {:error, _reason} ->
            case existing do
              [{^key, value, _inserted_at}] -> {:ok, value, stale: true}
              [] -> {:ok, []}
            end
        end
    end
  end

  defp client, do: Application.fetch_env!(:cleat_deploy, :analytics_client)

  defp server_id(%{id: id}), do: id
  defp server_id(_server), do: nil

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public])
        :ok

      _tid ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
