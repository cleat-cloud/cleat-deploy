defmodule CleatDeploy.Analytics.CaddyTest do
  use ExUnit.Case, async: true

  alias CleatDeploy.Analytics.Caddy

  @nfe %{
    slug: "nfe-facil",
    host: "nfe.gestaobem.com",
    port: 4033,
    analytics_inject: true,
    idle_shutdown_enabled: false,
    runtime: "phoenix",
    indexable: true
  }

  @cleat %{
    slug: "cleat",
    host: "cleat.sites.gestaobem.com",
    port: 4010,
    analytics_inject: true,
    idle_shutdown_enabled: false,
    runtime: "static",
    indexable: true
  }

  @static_root "/var/www/cleat/current"

  test "inject on runtime proxies analytics then fails over to the app" do
    site = Caddy.public_site(@nfe)

    assert site =~ "handle /cleat/a.js"
    assert site =~ "handle /cleat/a"
    assert site =~ "@cleat_ws"
    assert site =~ "Upgrade websocket"
    assert site =~ "reverse_proxy 127.0.0.1:8799 127.0.0.1:4033"
    assert site =~ "lb_policy first"
    assert site =~ "fail_duration 10s"
    assert site =~ "dial_timeout 250ms"
    refute site =~ "forward_auth"
    assert Caddy.loopback_site(@nfe) == nil
  end

  test "inject off runtime is a single reverse_proxy" do
    site = Caddy.public_site(%{@nfe | analytics_inject: false})

    assert site =~ "reverse_proxy 127.0.0.1:4033"
    refute site =~ "reverse_proxy 127.0.0.1:8799"
    refute site =~ "/cleat/a"
    refute site =~ ":8799"
  end

  test "inject on with wake keeps analytics handles before forward_auth" do
    site = Caddy.public_site(@nfe, wake_unit: "phoenix_nfe")

    a_idx = index!(site, "handle /cleat/a")
    auth_idx = index!(site, "forward_auth")
    ws_idx = index!(site, "handle @cleat_ws")

    assert a_idx < auth_idx
    assert auth_idx < ws_idx
    assert site =~ "uri /wake?unit=phoenix_nfe&port=4033"
  end

  test "inject on static public site proxies and loopback serves files" do
    site = Caddy.public_site(@cleat, static_root: @static_root)

    assert site =~ "reverse_proxy 127.0.0.1:8799 127.0.0.1:4010"
    assert site =~ "handle /cleat/a.js"
    assert site =~ "handle /cleat/a"
    refute site =~ "file_server"

    loopback = Caddy.loopback_site(@cleat, static_root: @static_root)
    assert loopback =~ "http://127.0.0.1:4010"
    assert loopback =~ "bind 127.0.0.1"
    assert loopback =~ "root *"
    assert loopback =~ "file_server"
    assert loopback =~ @static_root
  end

  test "inject off static serves files on the public host" do
    robots = ~s|header X-Robots-Tag "noindex, nofollow"|

    site =
      Caddy.public_site(%{@cleat | analytics_inject: false},
        static_root: @static_root,
        robots_header: robots
      )

    assert site =~ "file_server"
    assert site =~ "root * #{@static_root}"
    assert site =~ robots
    refute site =~ "reverse_proxy 127.0.0.1:8799 127.0.0.1:4010"
    refute site =~ "/cleat/a"

    assert Caddy.loopback_site(%{@cleat | analytics_inject: false}, static_root: @static_root) ==
             nil
  end

  defp index!(string, substring) do
    case :binary.match(string, substring) do
      {idx, _len} -> idx
      :nomatch -> flunk("expected #{inspect(substring)} in:\n#{string}")
    end
  end
end
