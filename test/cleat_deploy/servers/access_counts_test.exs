defmodule CleatDeploy.Servers.AccessCountsTest do
  use CleatDeploy.DataCase, async: false

  alias CleatDeploy.Servers.AccessCounts
  alias CleatDeploy.TenancyFixtures

  @now 1_700_000_000

  test "counts requests per host inside the time window" do
    log =
      Enum.join(
        [
          jason(%{ts: @now, request: %{host: "nfe.gestaobem.com"}}),
          jason(%{ts: @now, request: %{host: "nfe.gestaobem.com:443"}}),
          jason(%{ts: @now, request: %{host: "plaza.purplestock.com.br"}}),
          jason(%{ts: @now - 100_000, request: %{host: "nfe.gestaobem.com"}}),
          "not-json",
          jason(%{ts: @now, request: %{uri: "/"}})
        ],
        "\n"
      )

    counts = AccessCounts.count_hosts(log, since: @now - 86_400, now: @now)

    assert counts["nfe.gestaobem.com"] == 2
    assert counts["plaza.purplestock.com.br"] == 1
    refute Map.has_key?(counts, "nfe.gestaobem.com:443")
  end

  test "ranks apps by summed hosts and drops unknown traffic" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    nfe =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "NFe Fácil",
        slug: "nfe-facil",
        host: "nfe.gestaobem.com, nfe.apps.gestaobem.com"
      })

    plaza =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "Plaza",
        slug: "plaza",
        host: "plaza.purplestock.com.br"
      })

    _idle =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "Idle App",
        slug: "idle-app",
        host: "idle.example.com"
      })

    ranked =
      AccessCounts.rank(
        [nfe, plaza],
        %{
          "nfe.gestaobem.com" => 10,
          "nfe.apps.gestaobem.com" => 5,
          "plaza.purplestock.com.br" => 40,
          "random.example.com" => 99
        }
      )

    assert Enum.map(ranked, & &1.slug) == ["plaza", "nfe-facil"]
    assert hd(ranked).requests == 40
    assert List.last(ranked).requests == 15
    assert hd(ranked).id == plaza.id
  end

  test "snapshot reads the access log for the active server" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    TenancyFixtures.app_fixture(scope, server, %{
      name: "NFe Fácil",
      slug: "nfe-facil",
      host: "nfe.gestaobem.com"
    })

    other = TenancyFixtures.scope_fixture()
    other_server = TenancyFixtures.server_fixture(other)

    TenancyFixtures.app_fixture(other, other_server, %{
      name: "Secret",
      slug: "secret",
      host: "secret.example.com"
    })

    path = Path.join(System.tmp_dir!(), "cleat-access-#{System.unique_integer([:positive])}.log")

    File.write!(
      path,
      jason(%{ts: System.os_time(:second), request: %{host: "nfe.gestaobem.com"}}) <> "\n"
    )

    previous = Application.get_env(:cleat_deploy, :caddy_access_log_path)
    Application.put_env(:cleat_deploy, :caddy_access_log_path, path)

    on_exit(fn ->
      File.rm(path)

      if previous do
        Application.put_env(:cleat_deploy, :caddy_access_log_path, previous)
      else
        Application.delete_env(:cleat_deploy, :caddy_access_log_path)
      end
    end)

    [top] = AccessCounts.for_server(scope, server)
    assert top.slug == "nfe-facil"
    assert top.requests == 1
    assert AccessCounts.for_server(other, other_server) == []
  end

  test "ranks apps when sqlite stores custom_domain as lowercase text" do
    scope = TenancyFixtures.scope_fixture()
    server = TenancyFixtures.server_fixture(scope)

    nfe =
      TenancyFixtures.app_fixture(scope, server, %{
        name: "NFe Fácil",
        slug: "nfe-facil",
        host: "nfe.gestaobem.com"
      })

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE apps SET custom_domain = 'false' WHERE id = ?",
      [nfe.id]
    )

    path = Path.join(System.tmp_dir!(), "cleat-access-#{System.unique_integer([:positive])}.log")

    File.write!(
      path,
      jason(%{ts: System.os_time(:second), request: %{host: "nfe.gestaobem.com"}}) <> "\n"
    )

    previous = Application.get_env(:cleat_deploy, :caddy_access_log_path)
    Application.put_env(:cleat_deploy, :caddy_access_log_path, path)

    on_exit(fn ->
      File.rm(path)

      if previous do
        Application.put_env(:cleat_deploy, :caddy_access_log_path, previous)
      else
        Application.delete_env(:cleat_deploy, :caddy_access_log_path)
      end
    end)

    [top] = AccessCounts.for_server(scope, server)
    assert top.slug == "nfe-facil"
    assert top.requests == 1
  end

  test "ensure_caddyfile injects a global access logger once" do
    original = """
    {
    email admin@gestaobem.com
    on_demand_tls {
    ask http://127.0.0.1:4000/internal/domains/ask
    }
    }

    nfe.gestaobem.com {
    reverse_proxy 127.0.0.1:4033
    }
    """

    once = AccessCounts.ensure_caddyfile(original)
    twice = AccessCounts.ensure_caddyfile(once)

    assert once == twice
    assert once =~ "default_logger_name access"
    assert once =~ "/var/log/caddy/access.log"
    assert once =~ "nfe.gestaobem.com {"
    assert once =~ "email admin@gestaobem.com"
    assert once =~ "ask http://127.0.0.1:4000/internal/domains/ask"

    path =
      Path.join(System.tmp_dir!(), "cleat-caddy-#{System.unique_integer([:positive])}.caddyfile")

    py = Path.join(System.tmp_dir!(), "cleat-caddy-#{System.unique_integer([:positive])}.py")
    File.write!(path, original)
    File.write!(py, AccessCounts.ensure_python())

    on_exit(fn ->
      File.rm(path)
      File.rm(py)
    end)

    {_, 0} = System.cmd("python3", [py, path], stderr_to_stdout: true)
    assert File.read!(path) == once
  end

  defp jason(map), do: Jason.encode!(map)
end
