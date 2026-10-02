defmodule CleatDeploy.Analytics.Summary do
  @moduledoc """
  Reads sidecar pageview summaries over loopback or SSH. Never writes pageviews.

  `visited/1` caches `{server_id, :visited}` for 60s. HTTP errors return
  `{:ok, rows, stale: true}` when a cache entry exists, otherwise `{:ok, []}`.
  Stale error entries are served for 15s without refetching. `app/3` is not cached.
  """

  alias CleatDeploy.Analytics.SummaryStub

  @table __MODULE__
  @ttl_ms 60_000
  @error_ttl_ms 15_000

  def init_cache do
    ensure_table()
    :ok
  end

  def visited(nil), do: {:ok, []}

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

    case ets_lookup(key) do
      [{^key, {:stale, value}, inserted_at}] when now - inserted_at < @error_ttl_ms ->
        {:ok, value, stale: true}

      [{^key, {:stale, value}, _inserted_at}] ->
        fetch(key, fun, now, value)

      [{^key, value, inserted_at}] when now - inserted_at < @ttl_ms ->
        {:ok, value}

      existing ->
        fetch(key, fun, now, previous_value(existing))
    end
  end

  defp fetch(key, fun, now, previous) do
    case safe_fetch(fun) do
      {:ok, value} ->
        ets_insert({key, value, now})
        {:ok, value}

      {:error, _reason} when not is_nil(previous) ->
        ets_insert({key, {:stale, previous}, now})
        {:ok, previous, stale: true}

      {:error, _reason} ->
        {:ok, []}
    end
  end

  defp safe_fetch(fun) do
    case fun.() do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    exception -> {:error, exception}
  end

  defp previous_value([{_key, {:stale, value}, _inserted_at}]), do: value
  defp previous_value([{_key, value, _inserted_at}]), do: value
  defp previous_value([]), do: nil

  defp client, do: Application.fetch_env!(:cleat_deploy, :analytics_client)

  defp server_id(%{id: id}), do: id
  defp server_id(_server), do: nil

  defp ets_lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError ->
      ensure_table()
      :ets.lookup(@table, key)
  end

  defp ets_insert(record) do
    :ets.insert(@table, record)
  rescue
    ArgumentError ->
      ensure_table()
      :ets.insert(@table, record)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _tid ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
