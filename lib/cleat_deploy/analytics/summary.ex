defmodule CleatDeploy.Analytics.Summary do
  @moduledoc """
  Reads sidecar pageview summaries over loopback or SSH. Never writes pageviews.
  """

  alias CleatDeploy.Analytics.SummaryStub

  @table __MODULE__
  @ttl_ms 60_000

  @empty_app %{
    pageviews: 0,
    uniques: 0,
    series: [],
    paths: [],
    referrers: [],
    utm: [],
    stale: true
  }

  def visited(server) do
    client = client()

    if client == SummaryStub do
      client.visited(server)
    else
      cached({server_id(server), :visited}, fn -> client.visited(server) end, :visited)
    end
  end

  def app(server, host, range) when is_binary(host) and is_binary(range) do
    client = client()

    if client == SummaryStub do
      client.app(server, host, range)
    else
      cached(
        {server_id(server), :app, host, range},
        fn -> client.app(server, host, range) end,
        :app
      )
    end
  end

  defp cached(key, fun, kind) when is_function(fun, 0) do
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
            stale_or_empty(existing, kind)
        end
    end
  end

  defp stale_or_empty([{_key, value, _inserted_at}], :visited), do: {:ok, value, stale: true}

  defp stale_or_empty([{_key, value, _inserted_at}], :app),
    do: {:ok, Map.put(value, :stale, true)}

  defp stale_or_empty([], :visited), do: {:ok, []}
  defp stale_or_empty([], :app), do: {:ok, @empty_app}

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
