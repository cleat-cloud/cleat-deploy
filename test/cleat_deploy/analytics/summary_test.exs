defmodule CleatDeploy.Analytics.SummaryTest do
  use ExUnit.Case, async: false

  alias CleatDeploy.Analytics.Summary
  alias CleatDeploy.Analytics.SummaryStub

  defmodule FakeHttp do
    def visited(_server), do: next(:visited)
    def app(_server, _host, _range), do: next(:app)

    defp next(kind) do
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

  defp age_visited_cache(%{id: id}) do
    key = {id, :visited}
    [{^key, value, _inserted_at}] = :ets.lookup(Summary, key)
    true = :ets.insert(Summary, {key, value, System.monotonic_time(:millisecond) - 60_001})
  end
end
