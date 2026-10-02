defmodule CleatDeploy.Analytics.SummaryTest do
  use ExUnit.Case, async: false

  alias CleatDeploy.Analytics.Summary
  alias CleatDeploy.Analytics.SummaryHttp
  alias CleatDeploy.Analytics.SummaryStub

  defmodule FakeHttp do
    def visited(server) do
      count(:visited)
      next(:visited, server)
    end

    def app(_server, _host, _range) do
      count(:app)
      next(:app, nil)
    end

    def calls(kind), do: Process.get({__MODULE__, :calls, kind}, 0)

    defp count(kind) do
      key = {__MODULE__, :calls, kind}
      Process.put(key, Process.get(key, 0) + 1)
    end

    defp next(kind, _server) do
      key = {__MODULE__, kind}

      case Process.get(key, []) do
        [reply | rest] ->
          Process.put(key, rest)
          reply

        [] ->
          Application.get_env(:cleat_deploy, env_key(kind), {:error, :down})
      end
    end

    defp env_key(:visited), do: :analytics_fake_visited
    defp env_key(:app), do: :analytics_fake_app
  end

  test "visited uses the configured client" do
    Application.put_env(:cleat_deploy, :analytics_visited_stub, [
      %{host: "nfe.gestaobem.com", slug: "nfe-facil", pageviews: 42, id: 1, name: "NFe"}
    ])

    assert {:ok, [%{slug: "nfe-facil", pageviews: 42}]} =
             Summary.visited(%{host_ip: "203.0.113.9"})
  after
    Application.delete_env(:cleat_deploy, :analytics_visited_stub)
  end

  test "app returns the stub map" do
    server = %{host_ip: "203.0.113.9"}

    assert {:ok,
            %{
              pageviews: 0,
              uniques: 0,
              series: [],
              paths: [],
              referrers: [],
              utm: [],
              stale: false
            }} = Summary.app(server, "nfe.gestaobem.com", "24h")

    Application.put_env(:cleat_deploy, :analytics_app_stub, %{
      pageviews: 12,
      uniques: 4,
      series: [],
      paths: [%{path: "/login", pageviews: 8}],
      referrers: [%{referrer: "google.com", pageviews: 3}],
      utm: [%{source: "google", medium: "cpc", campaign: "a", pageviews: 2}],
      stale: false
    })

    assert {:ok, %{pageviews: 12, uniques: 4, stale: false}} =
             Summary.app(server, "nfe.gestaobem.com", "24h")
  after
    Application.delete_env(:cleat_deploy, :analytics_app_stub)
  end

  test "visited returns empty list for nil server" do
    assert {:ok, []} = Summary.visited(nil)
  end

  test "init_cache is idempotent" do
    assert :ok = Summary.init_cache()
    assert :ok = Summary.init_cache()
    assert is_reference(:ets.whereis(Summary))
  end

  describe "HTTP client" do
    setup do
      Application.put_env(:cleat_deploy, :analytics_client, FakeHttp)

      on_exit(fn ->
        Application.put_env(:cleat_deploy, :analytics_client, SummaryStub)
      end)

      %{server: %{id: System.unique_integer([:positive]), host_ip: "203.0.113.9"}}
    end

    test "visited returns empty list on cold cache HTTP error", %{server: server} do
      Process.put({FakeHttp, :visited}, [{:error, :down}])
      assert {:ok, []} = Summary.visited(server)
    end

    test "visited returns last cache with stale true after HTTP error", %{server: server} do
      rows = [%{host: "nfe.gestaobem.com", slug: "nfe-facil", pageviews: 42}]
      Process.put({FakeHttp, :visited}, [{:ok, rows}, {:error, :down}])

      assert {:ok, ^rows} = Summary.visited(server)
      age_visited_cache(server)
      assert {:ok, ^rows, stale: true} = Summary.visited(server)
      assert {:ok, ^rows, stale: true} = Summary.visited(server)
      assert FakeHttp.calls(:visited) == 2
    end

    test "visited returns empty list for nil server without fetching" do
      Process.put({FakeHttp, :visited}, [{:ok, [%{slug: "nope"}]}])
      assert {:ok, []} = Summary.visited(nil)
      assert FakeHttp.calls(:visited) == 0
    end

    test "app is pass-through with no cache", %{server: server} do
      payload = %{
        pageviews: 12,
        uniques: 4,
        series: [],
        paths: [],
        referrers: [],
        utm: [],
        stale: false
      }

      Process.put({FakeHttp, :app}, [{:ok, payload}, {:error, :down}])

      assert {:ok, ^payload} = Summary.app(server, "nfe.gestaobem.com", "24h")
      assert {:error, :down} = Summary.app(server, "nfe.gestaobem.com", "24h")
    end
  end

  test "http client rejects invalid servers without SSH" do
    assert {:error, :invalid_server} = SummaryHttp.visited(nil)
    assert {:error, :invalid_server} = SummaryHttp.visited("x")
    assert {:error, :invalid_server} = SummaryHttp.visited(%{id: 1})

    assert {:error, :invalid_server} =
             SummaryHttp.visited(%{id: 1, host_ip: "203.0.113.9"})

    assert {:error, :invalid_server} =
             SummaryHttp.app(%{id: 1, host_ip: "203.0.113.9"}, "nfe.gestaobem.com", "24h")
  end

  defp age_visited_cache(%{id: id}) do
    key = {id, :visited}

    case :ets.lookup(Summary, key) do
      [{^key, {:stale, value}, _inserted_at}] ->
        true = :ets.insert(Summary, {key, {:stale, value}, aged(60_001)})

      [{^key, value, _inserted_at}] ->
        true = :ets.insert(Summary, {key, value, aged(60_001)})
    end
  end

  defp aged(ms), do: System.monotonic_time(:millisecond) - ms
end
